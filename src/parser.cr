require "clang"
require "logger"
require "./clangutils"
require "./dfg"
require "./frontend/symbol_table"

module Isekai
    VERSION = "0.1.0"

    # Simple wrapper around the logger's instance.
    # Takes care of the Logger's setup and holds Logger instance
    class Log
      @@log = Logger.new(STDOUT)

      # Setup the logger
      # Parameters:
      #     verbose = be verbose at the output
      def self.setup (verbose = false)
          if verbose
              @@log.level = Logger::DEBUG
          else
              @@log.level = Logger::WARN
          end
      end

      # Returns:
      #     the logger instance
      def self.log
          @@log
      end
    end

    # Class that parses and transforms C code into internal state
    class CParser
        # Result of the C-AST -> internal format (DFG expression + symbol table)
        # transformation
        private class State
            def initialize(@expr : DFGExpr, @symtab : SymbolTable)
            end

            # Getter function for @expr member, used
            # to avoid the type-inference bug withing crystal
            def expr
                @expr
            end

            # Getter function for @symmember member, used
            # to avoid the type-inference bug withing crystal
            def symtab
                @symtab
            end
        end

        # Class analog to State, just returns a result of C type decoding
        private class TypeState
            def initialize(@type : Type, @symtab : SymbolTable)
            end

            def self.create(type, symtab)
                if type.is_a? Type
                    return TypeState.new(type, symtab)
                else
                    raise "Passing non-type to TypeState"
                end
            end
        end

        # Initialization method.
        # Parameters:
        #   input_file = C file to read
        #   clang_args = arguments to pass to clang (e.g. include directories)
        #   loop_sanity_limit = sanity limit to stop unrolling loops
        #   bit_width = bit width
        #   progress = print progress during processing
        def initialize (input_file : String, clang_args : String, @loop_sanity_limit : Int32,
                        @bit_width : Int32, @progress = false)
            @ast_cursor = CParser.parse_file_to_ast_tree(input_file, clang_args)
        end

        # Reads and parses the input file. Returns the AST tree representation.
        # Params:
        #     input_file = source file to parse
        #
        # Returns:
        #     cursor representing AST tree of the input file
        #
        def self.parse_file_to_ast_tree (input_file, clang_args) : Clang::Cursor
            # Creates a clang's index. Index holds the state of the parser
            # and it needs to be initialized before parsing
            index = Clang::Index.new

            # 1. Set default options
            options = Clang::TranslationUnit.default_options

            # 2. Load the file and get the translation unit
            files = [Clang::UnsavedFile.new(input_file, File.read(input_file))]
            tu = Clang::TranslationUnit.from_source(index, files, clang_args.split, options)

            # 3. return the cursor
            return tu.cursor
        end
    end
end
