require "clang"
require "logger"
require "./clangutils"
require "./dfg"
require "./frontend/symbol_table"

module Isekai
    # Indices of the arguments for the root call - first argument
    # is input, the second argument is NIZK, and the last
    # argument is the output arg.
    INPUT_ARG_IDX = 0
    NIZK_ARG_IDX = 1
    OUTPUT_ARG_IDX = -1

    # Transforms the entry point of the program to the DFGExpr
    # instance.
    def self.entry_point (symtab)
        if func_decl = @root_func_cursor
            params = ClangUtils.findFunctionParams(func_decl)

            has_nizk = false
            case params.size
            when 3
                has_nizk = true
            when 2
                has_nizk = false
            else
                raise "Malformed outsource func parameters"
            end

            arg_exprs = Array(DFGExpr).new()

            # Create expressions from arguments
            input_state = make_global_storage(params[INPUT_ARG_IDX], symtab)
            state = input_state
            arg_exprs << input_state.@expr

            if has_nizk
                nzik_state = make_global_storage(params[NIZK_ARG_IDX], state.@symtab)
                state = nzik_state
                arg_exprs << nzik_state.@expr
            end

            output_state = make_global_storage(params[OUTPUT_ARG_IDX], state.@symtab)
            state = output_state
            arg_exprs << output_state.@expr

            @inputs = Array(DFGExpr).new
            @nizk_inputs = Array(DFGExpr).new

            # Create internal symbol table for the funcction scope
            symtab = create_scope(params, arg_exprs, symtab)

            # For every input argument
            (0..2-1).each do |i|
                if i == 1 && !has_nizk
                    break
                end

                # The input argument symbol was declared in create_scope, look it up
                in_sym = Symbol.new(params[i].spelling)
                input_expr = symtab.lookup(in_sym)
                raise "Can't resolve input expression" if input_expr.is_a? Nil
                input_storage_ref : StorageRef = (input_expr.as StorageRef).deref()
                input_list = Array(DFGExpr).new

                # For every element in the input array, declare the Input/NIZKInput nodes
                (0..(input_storage_ref).@type.sizeof-1).each do |idx|
                    sk = StorageKey.new(input_storage_ref.@storage, idx)
                    if i == 0
                        input = dfg(Input, sk)
                        input_list << input
                        symtab.assign(sk, input)
                    else
                        input = dfg(NIZKInput, sk)
                        input_list << input
                        symtab.assign(sk, input)
                    end
                end

                # Assign the input nodes to class members
                if i == 0
                    @inputs = input_list
                else
                    @nizk_inputs = input_list
                end
            end

            func_body = ClangUtils.findFunctionBody(func_decl.definition)
            raise "Can't get root function's definition." if func_body.is_a? Nil

            Log.log.debug "Transforming function body: #{func_body}"
            result_symtab = transform_compound(func_body, symtab, true)

            # Lookup for the output expression and return it
            out_sym = Symbol.new(params[OUTPUT_ARG_IDX].spelling)
            output = (result_symtab.lookup(out_sym).as StorageRef).deref()
            return State.new(output, result_symtab)
        else
            raise "Couldn't find outsource function."
        end
    end

    # Convinience function to create DFGExpr.
    #
    # Params:
    #     dfg_name = name of the DFGExpr node
    #     args = arguments to pass to dfg_name's constructor
    #
    # Returns:
    #    instance of dfg_name instantiated with args
    def self.dfg (dfg_name, *args)
        return dfg_name.new(*args)
    end

    # Goes over the AST tree and creates the symbol table for the
    # root scope. It expects either variable declarations _or_
    # function declarations (which are ignored).
    def self.create_global_symtab ()
        symtab = SymbolTable.new
        # Goes over every symbol inside the root ast
        # and fills the symbol table
        @ast_cursor.visit_children do |cursor|
            case cursor.kind
            when .var_decl?
                symtab = declare_variable(cursor, symtab)
            when .function_decl?
                if @root_func_cursor.is_a? Nil && cursor.spelling == "outsource"
                    Log.log.debug "Found root function declaration"
                    @root_func_cursor = cursor
                else
                    Log.log.warn "Ignoring func. decl. " + cursor.spelling + " for now"
                end
            when .macro_definition?, .inclusion_directive?
                Log.log.debug "ignoring #{cursor.kind}: #{cursor}"
            when .struct_decl?
                Log.log.warn "ignoring #{cursor.kind} for now: #{cursor}"
            else
                puts cursor
                raise "Found unexpected element in AST, was expecting a declaration"
                next Clang::ChildVisitResult::Break
            end

            next Clang::ChildVisitResult::Continue
        end

        symtab.declare(PseudoSymbol.new("_unroll"), dfg(Undefined))
        return symtab
    end

    # Declares variable or a function argument (which is also a variable
    # inside given scope) inside symbol table
    def self.declare_variable (cursor, symtab, initial_value = nil)
        # Decode the type of the variable
        if cursor.kind == Clang::CursorKind::TypedefDecl
            decl_type = cursor.typedef_decl_underlying_type
            type_state = decode_type(decl_type, symtab, false)
            symtab = type_state.@symtab
        else
            type_state = decode_type(cursor, symtab, false)
            symtab = type_state.@symtab
        end

        # Declaration of variable, with the name (spelling)
        # We will get the initial value, allocate a storage (if
        # this is not a pointer) and insert this into a symbol
        # table.

        # Only two cursor types we accept here are variable
        # and parameter declaration. Also decays array into a pointer
        case cursor.kind
        when .var_decl?, .parm_decl?
            stored_type = type_state.@type

            if stored_type.is_a? ArrayType
                # array decays to a pointer
                var_type = PtrType.new(stored_type.@type)
            else
                var_type = stored_type
            end
        else
            puts "Can't resolve stored type - expecting variable/param declaration"
            ClangUtils.dumpCursorAst(cursor)
        end

        # make sure that the type is resolved. stored_type is C type,
        # while var_type is internal type. Normally, these are the same, unless
        # the stored_type is an array, in which case var_type is a pointer to
        # stored_type
        raise "Stored type is not resolved." unless !stored_type.is_a? Nil
        raise "Variable type could not be resolved." unless !var_type.is_a? Nil

        # Resolves the initial value. Either uses the provided initial value
        # or decodes the expression that's assigning the variable's value.
        initial_values = Array(SymbolTableValue).new
        has_initializer = initial_value.is_a? Nil

        if has_initializer
            ClangUtils.dumpCursorAst(cursor)
            raise "Providing an initial value with the value with initilizer" unless initial_value.nil?
        else
            if initial_value.nil?
                ClangUtils.dumpCursorAst(cursor)
                raise "Initial value is not supplied"
            end
            # Initial values are provided and they are already resolved symbols. Look them up
            # and add them to the initial values for every element in the type.
            if initial_value.is_a? StorageRef && !stored_type.is_a? PtrType
                (0..stored_type.sizeof-1).each do |i|
                    initial_values << symtab.lookup(StorageKey.new(initial_value.key.@storage, initial_value.key.@idx + i))
                end
            else
                initial_values << initial_value
            end
        end

        if has_initializer 
            case stored_type
            when ArrayType
                raise "Unimplemented TODO"
            when IntType
                # VarDecl cursor stores the initializer in the first child
                state = decode_expression_value(ClangUtils.getFirstChild(cursor), symtab)
                symtab = state.@symtab
                initial_values << state.@expr
            when PtrType
                # VarDecl cursor stores the initializer in the first child
                state = decode_ref(ClangUtils.getFirstChild(cursor), symtab)
                symtab = state.@symtab
                initial_values << state.@expr
            else
                raise "Variable declaration not supported: #{cursor}"
            end
        end

        symbol_value : (StorageRef|Nil)

        # allocate new Storage (not in case of a pointer, since
        # the storage is already allocated.
        if !(stored_type.is_a? PtrType)
            state = create_storage(cursor.spelling,
                                   stored_type, initial_values, symtab)
            storage_ref = state.@expr.as StorageRef
            symbol_value = dfg(StorageRef, var_type, storage_ref.@storage,
                               storage_ref.@idx)
            symtab = state.@symtab
        else
            if !initial_value.is_a? Nil
                symbol_value = initial_value.as StorageRef
            else
                symbol_value = dfg(StorageRef, stored_type, Null.new(), 0)
            end
        end

        raise "Symbol value is not resolved." unless !symbol_value.is_a? Nil

        # Either declare new symbol or reassign the existing one.
        sym = Symbol.new(cursor.spelling)
        if symtab.is_declared? sym
            # A duplicate declaration should match in type.
            # But that doesn't exactly work, because there may be a
            # pointer involved.
            Log.log.debug("Second declaration on #{sym}")
            defined_type = symtab.lookup(sym).as StorageRef
            if defined_type != symbol_value.@type
                raise "Value types don't match: #{defined_type} #{symbol_value.@type}"
            end

            # Rewrite the assignment to point at a new storage
            symtab.assign(sym, symbol_value)
        else
            Log.log.debug("Declaring #{sym} -> #{symbol_value}")
            symtab.declare(sym, symbol_value)
        end


        return symtab
    end

    # Resolves the reference (the pointer, pointer to a field,
    # etc.) and returns the destination element of this reference
    def self.decode_ref (cursor, symtab)
        raise "Trying to decode nil" unless !cursor.is_a? Nil
        Log.log.debug "Decoding ref: #{cursor}"

        # If the reference is a part of the compound statement,
        # this resolves the first expression.
        cursor = ClangUtils.resolveFirstExpr(cursor)

        case cursor.kind
        when .decl_ref_expr?
            symbol = symtab.lookup(Symbol.new(cursor.spelling))
            return State.new(symbol.as DFGExpr, symtab)
        when .member_ref_expr?
            result = decode_struct_ref(cursor, symtab)
        when .struct_decl?
            puts "Trying to find: #{cursor.spelling}"
            symbol = symtab.lookup(Symbol.new(cursor.spelling))
            return State.new(symbol.as DFGExpr, symtab)
            #when .array_ref?
            #    raise "Unimplemented TODO"
        when .type_ref?
            raise "Unimplemented TODO"
        when .unary_operator?
            result = decode_expression(cursor, symtab)
        else
            ClangUtils.dumpCursorAst(cursor)
            raise "Unsupported ref: #{cursor}"
        end

        return result
    end

    # Resolves the reference to the struct field. member_ref
    # is a cursor that's representing the reference to the
    # struct's field
    def self.decode_struct_ref (member_ref, symtab)
        # Get the cursor to parent struct
        struct_cursor = ClangUtils.getFirstChild(member_ref)
        raise "Can't find struct cursor" if struct_cursor.is_a? Nil
        puts "symtab: #{symtab.inspect}"

        # get the instance of the struct from the reference
        sref_state = decode_ref(struct_cursor, symtab)

        storage_ref = sref_state.@expr.as StorageRef
        symtab = sref_state.@symtab

        # in case the field is a pointer to the struct,
        # resolve the pointer.
        if struct_cursor.type.kind.pointer?
            storage_ref = storage_ref.deref()
        end

        # Get the field of the struct
        struct_type = storage_ref.@type.as StructType
        field = struct_type.get_field(member_ref.spelling)

        # Create the StorageRef DFG element
        fieldstorage = dfg(StorageRef,
                           field.@type,
                           storage_ref.@storage,
                           storage_ref.@idx + struct_type.offsetof(member_ref.spelling))
        return State.new(fieldstorage, symtab)
    end

    # Creates a storage (element in the symbol table) for the variable
    # and put it into the symbol table
    def self.create_storage (name, store_type : Type, initial_values, symtab)
        storage = Storage.new(name, store_type.sizeof)
        Log.log.warn "Creating storage #{storage.inspect} of #{store_type}"

        # Instantiate storage and set the initial values. For every
        # word inside a compound type, instantiate a StorageKey with the
        # right value and offset
        if !initial_values.is_a? Nil
            raise "The initial values doesn't match the type's size." \
                unless initial_values.size == store_type.sizeof

                    (0..initial_values.size-1).each do |i| 
                        puts "#{i} -> #{initial_values[i]}"
                        value = initial_values[i]
                        symtab.declare(StorageKey.new(storage, i), value)
                    end
            else
                (0..store_type.sizeof-1).each do |i|
                    symtab.declare(StorageKey.new(storage, i), dfg(Constant, 0))
                end
            end

            return State.new(dfg(StorageRef, store_type, storage, 0), symtab)
        end

        # Converts from the type AST cursor to the IntType/UnsignedType
        # storage symbol.
        def self.decode_scalar_type (type) : Type
            puts "type: #{type}. type spelling inspect: #{type.spelling}"
            type_string = type.spelling
            if type_string == "int"
                return IntType.new
            elsif type_string.starts_with? "unsigned"
                return UnsignedType.new
            end

            raise Exception.new
        end

        def self.decode_ptr_key (node)
            return Symbol.new(node.spelling)
        end

        def self.coerce_value (expr, symtab)
            # Original comment:
            # TODO is this correct? The expr may be a ref storage acquired early
            # in the eval process, then the symtab changed to update
            # that location. Hmm.
            # This is getting super-brittle. I really have no idea
            # which symtab the expr should be evaluated against to coerce
            # it down to a value. Probably should have bundled that into a
            # wrapper object. Ugh.
            if expr.is_a? StorageRef
                key = expr.key
                expr = symtab.lookup(key)
            end
            return expr
        end

        # Decodes the type of the cursor. Note that this expects the
        # entire cursor, and not just the cursor attached to the
        # type, because some (namely primitives/arrays) can be just figured
        # out by looking into the entire node).
        # Retuns the type of the associated symbol
        def self.decode_type (cursor : Clang::Cursor, symtab)
            # This goes as deep in the type declaration as needed
            # and it decodes the type.
            case cursor.kind
            when .var_decl?, .parm_decl? # Variable declaration?
                puts "Parsing the variable declaration: #{cursor.type}"
                puts "Spelling of the type '#{cursor.type.spelling}'"
                case cursor.type.kind
                when .int?, .u_int?
                    # variable declaration
                    puts "Found TypeState int"
                    result = TypeState.create(decode_scalar_type(cursor.type), symtab)
                when .elaborated?
                    Log.log.warn "Found an elaborated type: #{cursor.type}"
                    # this will reference a struct, which will be
                    # described in the TypeRef
                    if typeref_cursor = ClangUtils.getTypeRefChild(cursor)
                        result = decode_type(typeref_cursor, symtab)
                    else
                        raise "Couldn't find type_ref children for #{cursor}"
                    end
                when .pointer?
                    result = CParser.decode_type(cursor.type, symtab)
                when .constant_array?,
                    .incomplete_array?,
                    .variable_array?,
                    .dependent_sized_array?
                array_dimension = ClangUtils.getArrayDimension(cursor)
                dimension_state = CParser.decode_expression(array_dimension, symtab)
                end
            when .struct_decl?
                # struct declaration - create a new struct type
                # and add it to the symbol table
                struct_fields = Array(StructField).new

                ClangUtils.getStructFields(cursor).each do |field_cursor|
                    # recursively resolve this field
                    Log.log.warn "Decoding struct cursor #{field_cursor}"
                    type_state = CParser.decode_type(field_cursor.type, symtab, true)
                    symtab = type_state.@symtab
                    struct_fields << StructField.new(type_state.@type, field_cursor.spelling)
                end
                # against the code that uses structs.
                struct_type = StructType.new(cursor.spelling, struct_fields)
                symtab.declare(Symbol.new(cursor.spelling), struct_type)
                result = TypeState.create(struct_type, symtab)
            when .type_ref?
                # reference to the already existing type
                symbol = Symbol.new(cursor.spelling)
                Log.log.warn "Checking if #{symbol.@name} is already declared"
                if symtab.is_declared? symbol
                    # this references already declared type, look it up
                    type = symtab.lookup(Symbol.new(cursor.spelling))
                    result = TypeState.create(type, symtab)
                else
                    Log.log.warn "#{symbol.@name} is new, going further with #{cursor.type}"
                    result = CParser.decode_type(cursor.type.cursor, symtab)
                end 
            end

            if result 
                return result
            else
                ClangUtils.dumpCursorAst(cursor)
                raise Exception.new("Unknown type.")
            end
        end

        # For the given C type cursor (clang's pointer to a type) gets
        # an internal type
        def self.decode_type (type : Clang::Type, symtab)
            case type.kind
            when .int?, .u_int?
                result = TypeState.create(CParser.decode_scalar_type(type), symtab)
            when .record?
                Log.log.warn "Found a record #{type}"
            when .pointer?
                type_state = CParser.decode_type(type.pointee_type, symtab)
                symtab = type_state.@symtab
                result = TypeState.new(PtrType.new(type_state.@type), symtab)
            when .elaborated?
                result = CParser.decode_type(type.cursor, symtab)
            end

            if result 
                return result
            else
                puts "Unknown type detected: #{type}"
                raise Exception.new("Unknown type: #{type}")
            end
        end

        # Resolves the expression and gets its value
        def self.decode_expression_value (expression, symtab) : State
            return decode_expression(expression, symtab)
        end

        # Resolves the expression and gets its value, if the
        # expression is a literal
        def self.decode_expression (literal : Int32, symtab) : State
            return State.new(dfg(Constant, literal), symtab)
        end

        # Takes an expression and a symbol table, and recursively transforms
        # the entire expression into the internal DFGExpr and symtable pair
        def self.decode_expression (expression, symtab, void = false) : State
            raise "Passed Nil expression" unless !expression.is_a? Nil

            # For the given clang expression, we can decode
            # every kind.
            case expression.kind
            when .call_expr? # Function call
                # Forwards the decoding to the decode_funccall method
                state = decode_funccall(expression, symtab)
                if !void && state.expr.is_a? Void
                    ClangUtils.dumpCursorAst(expression)
                    raise VoidFuncUsedAsExpression.new()
                end
                return state
            when .binary_operator?
                # Binary operator is represented by the left and the right
                # operand, so we'll decode both sides and create DFGExpr
                # using the right operator
                children = ClangUtils.getBinaryOperatorExprs(expression)
                left_state : State = decode_expression_value(children[0], symtab)
                right_state : State = decode_expression_value(children[1], symtab)
                raise "Couldn't decode binary op." if (left_state.is_a? Nil || right_state.is_a? Nil)

                case expression.spelling
                when "+"
                    dfg_expr = dfg(Add, left_state.expr, right_state.expr)
                when "-"
                    dfg_expr = dfg(Subtract, left_state.expr, right_state.expr)
                when "*"
                    dfg_expr = dfg(Multiply, left_state.expr, right_state.expr)
                when "<"
                    dfg_expr = dfg(CmpLT, left_state.expr, right_state.expr)
                when "<="
                    dfg_expr = dfg(CmpLEQ, left_state.expr, right_state.expr)
                when "=="
                    dfg_expr = dfg(CmpEQ, left_state.expr, right_state.expr)
                when ">"
                    dfg_expr = dfg(CmpGT, left_state.expr, right_state.expr)
                when ">="
                    dfg_expr = dfg(CmpGEQ, left_state.expr, right_state.expr)
                when "/"
                    dfg_expr = dfg(Divide, left_state.expr, right_state.expr)
                when "%"
                    dfg_expr = dfg(Modulo, left_state.expr, right_state.expr)
                when "^"
                    dfg_expr = dfg(Xor, left_state.expr, right_state.expr)
                when "<<"
                    dfg_expr = dfg(LeftShift, left_state.expr, right_state.expr, @bit_width)
                when ">>"
                    dfg_expr = dfg(RightShift, left_state.expr, right_state.expr, @bit_width)
                when "|"
                    dfg_expr = dfg(BitOr, left_state.expr, right_state.expr)
                when "&"
                    dfg_expr = dfg(BitAnd, left_state.expr, right_state.expr)
                when "&&"
                    dfg_expr = dfg(LogicalAnd, left_state.expr, right_state.expr)
                else
                    raise "I don't know this binary expression: #{expression}"
                end
                return State.new(dfg_expr, right_state.symtab)
            when .unary_operator?
                # Unary operator - unwrap the operand (may be hidden behind FirstExpr)
                child = ClangUtils.getFirstChild(expression)
                raise "Unary expression incomplete" unless !child.is_a? Nil
                if child.kind.first_expr?
                    child = ClangUtils.getFirstChild(child) 
                end
                raise "Unary expression incomplete" unless !child.is_a? Nil
                puts "Child: #{child} op str: #{expression.operator_str}"

                case expression.operator_str
                when "*"
                    Log.log.debug "Decoding reference: #{expression} -> #{child}"
                    state = decode_ref(child, symtab)
                    return State.new((state.expr.as StorageRef).deref(), state.symtab)
                when "-"
                    Log.log.debug "Resolving negate"
                    state = decode_expression_value(child, symtab)
                    return State.new(dfg(Negate, state.expr), state.symtab)
                when "!"
                    Log.log.debug "Resolving logical not"
                    state = decode_expression_value(child, symtab)
                    return State.new(dfg(LogicalNot, state.expr), state.symtab)
                when "&"
                    Log.log.debug "Decoding unary &"
                    sub_state = decode_ref(child, symtab)
                    symtab = sub_state.symtab
                    Log.log.debug "For #{child} got expr #{sub_state.expr}"
                    ref = sub_state.expr.as(StorageRef).ref()
                    return State.new(ref, symtab)
                end
                raise "Unknown unary operator: #{expression}"
            when .integer_literal?
                value = ClangUtils.getCursorValue(expression)
                raise "Integer literal can't be resolved #{expression}" unless !value.is_a? Nil
                return State.new(dfg(Constant, value), symtab)
                # This is a just a wrapper around real expression,
                # in order to resolve it, we just unwrap it and do it recursively
            when .first_expr?
                if child = ClangUtils.getFirstChild(expression)
                    return decode_expression_value(child, symtab)
                else
                    raise "Can't resolve FirstExpr TODO #{expression}"
                end
            when .decl_ref_expr?
                # Reference to an already declared symbol
                symbol = symtab.lookup(Symbol.new(expression.spelling))
                return State.new(symbol.as DFGExpr, symtab)
            when .member_ref_expr?
                # Reference to the member of the compound type
                state = decode_ref(expression, symtab)
                return State.new(state.expr, state.symtab)
            when .paren_expr?
                # The expression is hidden behind the paren - unwrap it
                # and decode the iner content of the parenthesis.
                return decode_expression(ClangUtils.getFirstChild(expression), symtab)
            else
                ClangUtils.dumpCursorAst(expression)
                raise "Unknown expression #{expression}"
            end
        end

        # Transforms the function call. Sets up the symbol
        # table, calculates the side effects from the function
        # definition, and returns resulting expression and
        # the resulting symbolic table.
        def self.decode_funccall (func_call_cursor, symtab)
            # current_symtab points to the current state
            # of the symbol table.
            current_symtab = symtab
            func_decl_cursor = func_call_cursor.referenced
            raise "Can't find FunctionDecl from CallExpr" if func_decl_cursor.is_a? Nil
            function_body = func_decl_cursor.definition
            raise "Can't find function body from FunctionDecl" if function_body.is_a? Nil
            Log.log.debug "Function body resolved: #{ClangUtils.dumpCursorAst(function_body)}"

            # array of function argument expressions
            function_argument_exprs = Array(DFGExpr).new()

            func_call_cursor.arguments.each do |func_arg|
                res_state = decode_expression(func_arg, current_symtab)
                function_argument_exprs << res_state.@expr
                current_symtab = res_state.@symtab
            end

            # Get the parameters for the function
            param_decls = ClangUtils.findFunctionParams(func_decl_cursor)

            # create symbol table for the function call,
            # apply the function call and get the resulting expression
            function_call_symtab = create_scope(param_decls,
                                                function_argument_exprs, current_symtab)

            # Convert the function body - compound statement and get the resulting
            # symbol table - containing all the side effects
            side_effect_symtab = transform_compound(function_body,
                                                    function_call_symtab, true)

            # apply the side effects from the function call
            # to the global symbol table
            result_symtab = function_call_symtab.apply_changes(
                side_effect_symtab, current_symtab)

            # Try to find `return` symbol - result expression
            begin
                result_expr = side_effect_symtab.lookup(PseudoSymbol.new("return"))
            rescue UndefinedSymbolException
                result_expr = Void.new()
            end
            Log.log.debug "Result expression  #{result_expr}"

            raise "Result expression is not DFGExpr" unless result_expr.is_a? DFGExpr

            # Return the final return expression and the new symbol table
            return State.new(result_expr.as DFGExpr, result_symtab)
        end

        # Creates a new scope - creates a child symbol table in the current one and
        # it declares all function arguments inside it.
        def self.create_scope (param_decls, function_argument_exprs, current_symtab)
            new_symtab = SymbolTable.new(current_symtab, nil)
            raise "Mismatch in scope declarations/passed args" if param_decls.size != function_argument_exprs.size

            (0..param_decls.size-1).each do |i|
                new_symtab = declare_variable(param_decls[i], new_symtab, function_argument_exprs[i])
            end

            return new_symtab
        end

        # Transforms a compound statement - e.g. function body into an internal state and returns
        # the new symbol table with all side effects.
        def self.transform_compound (compound, symtab, function_scope = false)
            raise "transform_compound accepts only compound statement" unless compound.kind.compound_stmt?
            puts "In transform_compound"
            working_symtab = symtab

            # Visit every statement in the group and transform it.
            has_return = false
            compound.visit_children do |child|
                # we can't have more children in AST after return
                if has_return
                    raise "Early return not allowed"
                end

                working_symtab = transform_statement(child, working_symtab)

                if child.kind.return_stmt?
                    has_return = true
                end

                Clang::ChildVisitResult::Continue
            end
            return working_symtab
        end

        # Delegates the statement to the transform function based on its type
        def self.transform_statement (statement, working_symtab)
            case statement.kind
            when .compound_stmt?
                working_symtab = transform_compound(statement, working_symtab)
            when .var_decl?
                working_symtab = declare_variable(statement, working_symtab)
            when .call_expr?
                state = decode_expression_value(statement, working_symtab)
                working_symtab = state.@symtab
            when .for_stmt?
                working_symtab = transform_for(statement, working_symtab)
            when .if_stmt?
                working_symtab = transform_if_statement(statement, working_symtab)
            when .return_stmt?
                return_state = decode_expression_value(ClangUtils.getFirstChild(statement), working_symtab)
                working_symtab = return_state.@symtab
                working_symtab.declare(PseudoSymbol.new("return"), return_state.@expr)
            when .binary_operator?
                raise "Expecting assignment operator" unless (statement.spelling == "=")
                working_symtab = transform_assignment(statement, working_symtab)
            else
                raise "Can't resolve statement #{statement.inspect}"
            end
            return working_symtab
        end

        # Transforms the assignment operator. It tries to fold the right side
        # as much as possible and to assign the most simple expression to the
        # target symbol
        def self.transform_assignment (statement, symtab)
            assignment_parts = ClangUtils.getBinaryOperatorExprs(statement)

            # In case of a simple assignment, only the right side should be
            # resolved. In case of the compound assignment operator (e.g. +=)
            # both expressions needs to be resolved, since a += b is equivalent
            # to a = a + b
            if statement.spelling == "="
                right_state = decode_expression(assignment_parts[1], symtab)
                symtab = right_state.@symtab
                expr = (right_state.@expr.as DFGExpr)
            elsif statement.spelling.size == 2 && statement.spelling[1] == '='
                left_state = decode_expression(assignment_parts[0], symtab)
                right_state = decode_expression(assignment_parts[1], left_state.@symtab)

                case statement.spelling
                when "+="
                    expr = dfg(Add, left_state.@expr, right_state.@expr)
                when "-="
                    expr = dfg(Subtract, left_state.@expr, right_state.@expr)
                when "*="
                    expr = dfg(Multiply, left_state.@expr, right_state.@expr)
                when "|="
                    expr = dfg(Divide, left_state.@expr, right_state.@expr)
                else
                    raise "Unexpected assignment operator: #{statement}"
                end

                symtab = right_state.@symtab
            else
                raise "Unexpected assignment operator: #{statement}"
            end

            raise "Can't resolve assignment expression" if expr.is_a? Nil

            # _unroll is a special variable (PseudoSymbol) providing a hint for the compiler
            # how many times to unroll the loop. If found on the left side,
            # do not try to search for it - it was never declared in the program
            # so just create a new symbol and assign the resulting expression to it
            lvalue = assignment_parts[0]
            if lvalue.kind.first_ref? && lvalue.spelling == "_unroll"
                sym = PseudoSymbol.new("_unroll")
                symtab.assign(sym, expr)
            else
                # The left side must be previously declared, so find it in the
                # symbol table
                lvalue_state = decode_ref(lvalue, symtab)
                lvalue_expr = lvalue_state.@expr.as StorageRef

                symtab = lvalue_state.@symtab

                # In case it's a pointer, find the resulting symbol
                if lvalue_expr.is_ptr?
                    sym = decode_ptr_key(lvalue)
                    symtab.assign(sym, expr)
                else
                    # If not a pointer, assign all parts of the resulting
                    # expression to the coresponding members
                    sym = lvalue_expr.key
                    size = lvalue_expr.@type.sizeof()

                    if size > 1
                        lkey = lvalue_expr.as StorageRef
                        rkey = expr.as StorageRef
                        (0..size-1).each do |i|
                            symtab.assign(lkey.offset_key(i),
                                          symtab.lookup(rkey.offset_key(i)))
                        end
                    else
                        expr = coerce_value(expr, symtab)
                        symtab.assign(sym, expr)
                    end
                end
            end

            return symtab
        end

        # Transforms the if-else statement into the DExpr graph.
        # It tries to evaluate the expression statically and if it can,
        # it inserts only the appropriate branch. Otherwise, both are evaluated
        # and the graph is updated is updated.
        def self.transform_if_statement (if_statement, symtab)
            # This returns an array of cursors where the first 
            # entry is the condition, the second entry is the then body
            # and optional third is the else part
            if_parts = ClangUtils.getIfStatementExprs(if_statement)
            cond_state = decode_expression_value(if_parts[0], symtab)

            begin
                cond_val = evaluate(cond_state.@expr)
                if cond_val
                    return transform_statement(if_parts[1], symtab)
                elsif if_parts.size == 3
                    return transform_statement(if_parts[2], symtab)
                else
                    return symtab #noop
                end
            rescue ex : NonconstantExpression
                # In case the branch is a non-constant expression
                # evaluate both branches and make resulting storage updates
                # conditional on the dynamic condition

                # Declare scopes
                then_scope = SymbolTable.new(symtab, Set(Key).new)
                then_symtab = transform_statement(if_parts[1], then_scope)
                else_scope = SymbolTable.new(symtab, Set(Key).new)

                if if_parts.size == 3
                    else_symtab = transform_statement(if_parts[2], else_scope)
                else
                    else_symtab = else_scope
                end

                new_symtab = symtab

                # Find all identifiers that are potentially changed
                modified_idents = then_scope.getScope | else_scope.getScope

                # Wrap every identifier in the conditional expression
                modified_idents.each do |id|
                    expr = dfg(Conditional, cond_state.@expr,
                               then_symtab.lookup(id).as DFGExpr, else_symtab.lookup(id).as DFGExpr)
                    new_symtab.assign(id, expr)
                end
                return new_symtab
            end
        end

        # Transforms the for loop - resolves the initial statement and transforms
        # the loop body and increment
        def self.transform_for (for_statement, working_symtab)
            # Resolve the initialisation statement
            working_symtab = transform_statement(for_statement.for_init, working_symtab)

            # Transforms the looop
            return transform_loop(for_statement.for_cond,
                                  for_statement.for_body, for_statement.for_inc,
                                  working_symtab)
        end

        # Evaluates the loop. Tries to statically evaluate loop's condition
        # value and fails to the dynamic loop unrolling if that fails.
        def self.transform_loop(cond, body, inc, symtab)
            working_symtab = symtab

            cond_state = decode_expression_value(cond, working_symtab)

            begin
                begin
                    cond_val = evaluate(cond_state.@expr)
                rescue ex : NonconstantExpression
                    Log.log.debug("Falling back to dynamic unrolling")
                    raise ex
                rescue e : Exception
                    Log.log.debug "Got exception evaluating condition: #{e.inspect}"
                    raise e
                end

                begin
                    return unroll_static_loop(cond, body, inc, symtab)
                rescue NonconstantExpression
                    raise "Unexpected nonconstant expression"
                end
            rescue NonconstantExpression
                return unroll_dynamic_loop(cond, body, inc, symtab)
            end
        end

        # Tries to unroll the loop statically.
        # cond - loop contition statement 
        # body - loop's body compound statement,
        # inc - loop's increment statement
        def self.unroll_static_loop(cond, body, inc, symtab)
            @loops += 1
            @sanity = -1
            working_symtab = symtab

            # Loops around, evaluates the loop's condition value and
            # executes the loop's body
            while true
                @sanity += 1
                if @sanity > @loop_sanity_limit
                    puts "Statically infinite loop: #{cond} #{body} #{inc}"
                end

                # Decode the condition
                cond_state = decode_expression_value(cond, working_symtab)
                cond_val = evaluate(cond_state.@expr)

                # Break?
                if cond_val.is_a? Nil
                    break
                end

                # Transform the loop's body and increment
                working_symtab = transform_statement(body, cond_state.@symtab)
                if !inc.is_a? Nil
                    working_symtab = transform_statement(inc, working_symtab)
                end
            end

            @loops -= 1
            return working_symtab
        end

        # Unrolls the loop which condition can't be evaluated statically
        def unroll_dynamic_loop(cond, body, inc, symtab)
            @loops += 1
            
            # Read the hint how deep the conditional's stack should be 
            _unroll_val = evaluate(symtab.lookup(PseudoSymbol.new("_unroll")).as DFGExpr)

            working_symtab = symtab
            cond_stack = Array(DFGExpr).new
            scope_stack = Array(SymbolTable).new

            # Build nested scopes up to _unroll hint
            (0.._unroll_val-1).each do |i|
                cond_state = decode_expression_value(cond, working_symtab)
                scope = SymbolTable.new(cond_state.@symtab, Set(Key).new)
                cond_stack << cond_state.@expr
                scope_stack << scope

                working_symtab = transform_statement(body, scope)
                if !inc.is_a? Nil
                    working_symtab = transform_statement(inc, working_symtab)
                end
            end          

            # Unroll the scopes and apply changes
            while (cond_stack.size > 0)
                cond = cond_stack.pop()
                scope = scope_stack.pop()
                raise "Mismatch between scope and cond stack size" if cond.is_a? Nil
                raise "Mismatch between scope and cond stack size" if scope.is_a? Nil
                modified_idents = scope.@scope
                raise "Missing scope in dynamic loop unrolling" if modified_idents.is_a? Nil

                applied_symtab = working_symtab
                modified_idents.each do |id|
                    parent_scope = scope.@parent
                    raise "Unexpected scope without parent" if parent_scope.is_a? Nil
                    applied_symtab.assign(id,
                            dfg(Conditional, cond,
                                working_symtab.lookup(id).as DFGExpr,
                                parent_scope.lookup(id).as DFGExpr))
                end
                working_symtab = applied_symtab
            end

            @loops -= 1
            return working_symtab
        end

        #TODO - glue layer
        def evaluate (expr : DFGExpr) : Int32|Nil
            return 0
        end 

        # Make a global variable
        def make_global_storage(node, symtab)
            type_state = decode_type(node, symtab)
            ptr_type : PtrType = type_state.@type.as PtrType
            store_type = ptr_type.@base_type
            state = create_storage(node.spelling, store_type, nil, symtab)
            symtab = state.@symtab
            state_storage_ref = state.@expr.as StorageRef 
            symbol_value = dfg(StorageRef, ptr_type, state_storage_ref.@storage,
                               state_storage_ref.@idx)
            return State.new(symbol_value, symtab)
        end
end
