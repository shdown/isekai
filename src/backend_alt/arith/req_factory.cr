require "big"
require "./board"
require "./bit_manip"
require "./dynamic_range"

@[AlwaysInline]
private def truncate (x : UInt128, width : Int32) : UInt128
    x & ((1_u128 << width) - 1)
end

@[AlwaysInline]
private def common_width! (a : Int32, b : Int32) : Int32
    raise "Bit widths differ" unless a == b
    return a
end

module Isekai::AltBackend::Arith

struct RequestFactory

    struct NagaiConstant
        def initialize (@value : BigInt)
        end
    end

    struct NagaiWire
        def initialize (@wire : Wire)
        end
    end

    alias NagaiRequest = NagaiConstant | NagaiWire

    struct JoinedRequest
        # This represents the value of 'a*x+b'. Constants are represented as '0*I+b', where 'I' is
        # an "invalid" wire.
        def initialize (@a : UInt128, @x : Wire, @b : UInt128, @width : Int32)
        end

        getter width

        @[AlwaysInline]
        def self.new_for_wire (w : Wire, width : Int32)
            self.new(a: 1, x: w, b: 0, width: width)
        end

        @[AlwaysInline]
        def self.new_for_const (c : UInt128, width : Int32)
            self.new(a: 0, x: Wire.new_invalid, b: c, width: width)
        end

        @[AlwaysInline]
        def constant?
            @a == 0
        end

        @[AlwaysInline]
        def as_constant : UInt128?
            @a == 0 ? @b : nil
        end
    end

    alias SplitRequest = Array(JoinedRequest)

    @board : Board

    def initialize (@board)
    end

    private def bake_joined_or_nagai_request (wire, bitwidth) : JoinedRequest | NagaiRequest
        if bitwidth.undefined?
            NagaiWire.new(wire)
        else
            JoinedRequest.new_for_wire(wire, width: bitwidth.@width)
        end
    end

    def bake_input (idx : Int32) : JoinedRequest | NagaiRequest
        wire, bitwidth = @board.input(idx)
        bake_joined_or_nagai_request(wire, bitwidth)
    end

    def bake_nizk_input (idx : Int32) : JoinedRequest | NagaiRequest
        wire, bitwidth = @board.nizk_input(idx)
        bake_joined_or_nagai_request(wire, bitwidth)
    end

    def bake_const (c : UInt128, width : Int32) : JoinedRequest
        return JoinedRequest.new_for_const(c, width: width)
    end

    private def joined_to_wire! (j : JoinedRequest, truncate : Bool = true) : Wire
        if j.constant?
            return @board.constant(j.@b)
        else
            ax = @board.const_mul(
                j.@a,
                j.@x,
                policy: OverflowPolicy.new_wrap_around(j.@width))
            result = @board.const_add(
                j.@b,
                ax,
                policy: OverflowPolicy.new_wrap_around(j.@width))
            if truncate
                result = @board.truncate(result, to: j.@width)
            end
            result
        end
    end

    def joined_add_output! (j : JoinedRequest) : Nil
        @board.add_output!(joined_to_wire! j)
    end

    def joined_add_const (c : UInt128, j : JoinedRequest) : JoinedRequest
        return JoinedRequest.new(
            a: j.@a,
            x: j.@x,
            b: truncate(c &+ j.@b, j.@width),
            width: j.@width)
    end

    def joined_add (j : JoinedRequest, k : JoinedRequest) : JoinedRequest
        width = common_width! j.@width, k.@width

        if j.@x == k.@x
            return JoinedRequest.new(
                a: truncate(j.@a &+ k.@a, width),
                x: j.@x,
                b: truncate(j.@b &+ k.@b, width),
                width: width)
        end
        return joined_add_const(j.@b, k) if j.constant?
        return joined_add_const(k.@b, j) if k.constant?

        j_ax = @board.const_mul(
            j.@a,
            j.@x,
            policy: OverflowPolicy.new_wrap_around(width))
        k_ax = @board.const_mul(
            k.@a,
            k.@x,
            policy: OverflowPolicy.new_wrap_around(width))
        sum_ax = @board.add(
            j_ax,
            k_ax,
            policy: OverflowPolicy.new_wrap_around(width))
        return JoinedRequest.new(
            a: 1,
            x: sum_ax,
            b: truncate(j.@b &+ k.@b, width),
            width: width)
    end

    def joined_mul_const (c : UInt128, j : JoinedRequest)
        return JoinedRequest.new(
            a: truncate(c &* j.@a, j.@width),
            x: j.@x,
            b: truncate(c &* j.@b, j.@width),
            width: j.@width)
    end

    def joined_mul (j : JoinedRequest, k : JoinedRequest) : JoinedRequest
        width = common_width! j.@width, k.@width

        return joined_mul_const(j.@b, k) if j.constant?
        return joined_mul_const(k.@b, j) if k.constant?

        if width == 1 && j.@x == k.@x
            # Modulo 2, x^2 = x, so:
            # (x + A)(x + B) = x^2 + Ax + Bx + AB = (A+B+1)x + AB
            return JoinedRequest.new(
                a: j.@b ^ k.@b ^ 1,
                x: j.@x,
                b: j.@b & k.@b,
                width: 1)
        end

        j_wire = joined_to_wire! j, truncate: false
        k_wire = joined_to_wire! k, truncate: false
        result = @board.mul(
            j_wire,
            k_wire,
            policy: OverflowPolicy.new_wrap_around(width))
        return JoinedRequest.new_for_wire(result, width: width)
    end

    def joined_sub (j : JoinedRequest, k : JoinedRequest) : JoinedRequest | SplitRequest
        width = common_width! j.@width, k.@width
        minus_one = (1_u128 << width) - 1
        return joined_add(j, joined_mul_const(minus_one, k))
    end

    private def cond_wcc (c : Wire, t : UInt128, f : UInt128, width : Int32) : JoinedRequest
        diff = t.to_i128 - f.to_i128
        if diff == 0
            return JoinedRequest.new_for_const(f, width: width)
        end

        c = @board.truncate(c, to: 1)
        if diff > 0
            left_summand = @board.const_mul(
                diff.to_u128,
                c,
                policy: OverflowPolicy.new_set_undef_range)
        else
            left_summand = @board.const_mul_neg(
                (-diff).to_u128,
                c)
        end

        result = @board.const_add(
            f,
            left_summand,
            policy: OverflowPolicy.new_set_undef_range)

        @board.assume_width!(
            result,
            Math.max(BitManip.nbits(t), BitManip.nbits(f)))

        return JoinedRequest.new_for_wire(result, width: width)
    end

    def joined_cond (c : JoinedRequest, t : JoinedRequest, f : JoinedRequest) : JoinedRequest
        width = common_width! t.@width, f.@width
        if c.constant?
            return (c.@b != 0) ? t : f
        end
        if c.@b != 0
            t, f = f, t
            c = JoinedRequest.new_for_wire(c.@x, width: 1)
        end

        if f.constant? && t.constant?
            return cond_wcc(c.@x, t.@b, f.@b, width: width)
        end

        if t.@x == f.@x && t.@a == f.@a
            return joined_add(
                JoinedRequest.new(a: t.@a, x: t.@x, b: 0, width: width),
                cond_wcc(c.@x, t.@b, f.@b, width: width))
        end

        c_wire = @board.truncate(c.@x, to: 1)
        t_wire = joined_to_wire! t, truncate: false
        f_wire = joined_to_wire! f, truncate: false

        t_max_nbits = @board.max_nbits(t_wire).not_nil!
        f_max_nbits = @board.max_nbits(f_wire).not_nil!

        minus_f_wire = @board.const_mul_neg(
            1,
            f_wire)
        t_minus_f_wire = @board.add(
            t_wire,
            minus_f_wire,
            policy: OverflowPolicy.new_set_undef_range)
        left_summand = @board.mul(
            c_wire,
            t_minus_f_wire,
            policy: OverflowPolicy.new_set_undef_range)
        result = @board.add(
            left_summand,
            f_wire,
            policy: OverflowPolicy.new_set_undef_range)

        @board.assume_width!(
            result,
            Math.max(t_max_nbits, f_max_nbits))

        return JoinedRequest.new_for_wire(result, width: width)
    end

    def joined_or_1bit (j : JoinedRequest, k : JoinedRequest) : JoinedRequest
        if j.constant?
            return (j.@b != 0) ? j : k
        end
        if k.constant?
            return (k.@b != 0) ? k : j
        end
        j_wire = joined_to_wire! j
        k_wire = joined_to_wire! k
        jk = @board.mul(
            j_wire,
            k_wire,
            policy: OverflowPolicy.new_set_undef_range)
        minus_jk = @board.const_mul_neg(
            1,
            jk)
        k_minus_jk = @board.add(
            k_wire,
            minus_jk,
            policy: OverflowPolicy.new_set_undef_range)
        result = @board.add(
            j_wire,
            k_minus_jk,
            policy: OverflowPolicy.new_set_undef_range)

        @board.assume_width!(result, 1)

        return JoinedRequest.new_for_wire(result, width: 1)
    end

    def joined_zerop (j : JoinedRequest) : JoinedRequest
        if j.constant?
            return JoinedRequest.new_for_const(j.@b == 0 ? 0_u128 : 1_u128, width: 1)
        else
            j_wire = joined_to_wire! j
            result = @board.zerop(j_wire)
            return JoinedRequest.new_for_wire(result, width: 1)
        end
    end

    def joined_dload (values :  Array(JoinedRequest), idx : JoinedRequest) : JoinedRequest
        value_width = values[0].@width
        unless values.all? { |v| v.@width == value_width }
            raise "Bit widths differ"
        end
        if idx.constant?
            return values[idx.@b]? || JoinedRequest.new_for_const(0_u128, width: value_width)
        end
        wires = values.map { |v| joined_to_wire! v, truncate: false }
        idx_wire = joined_to_wire! idx
        result = @board.dload(wires, idx_wire)
        return JoinedRequest.new_for_wire(result, width: value_width)
    end

    def joined_asplit_prepare (j : JoinedRequest) : JoinedRequest
        if j.constant?
            j
        else
            JoinedRequest.new_for_wire(
                joined_to_wire!(j),
                width: j.@width)
        end
    end

    def joined_asplit (j : JoinedRequest, nindices : Int32) : Array(JoinedRequest)
        if j.constant?
            return Array(JoinedRequest).new(nindices) do |i|
                JoinedRequest.new_for_const(j.@b == i ? 1_u128 : 0_u128, width: 1)
            end
        end
        j_wire = joined_to_wire! j
        bits = @board.asplit(j_wire, nindices)
        return Array(JoinedRequest).new(nindices) do |i|
            if i < bits.size
                JoinedRequest.new_for_wire(bits[i], width: 1)
            else
                JoinedRequest.new_for_const(0_u128, width: 1)
            end
        end
    end

    def joined_zero_extend (j : JoinedRequest, to new_width : Int32) : JoinedRequest | SplitRequest
        old_width = j.@width
        return j if old_width == new_width
        raise "This is truncation, not extension" if new_width < old_width

        if j.constant?
            return JoinedRequest.new_for_const(j.@b, width: new_width)
        else
            j_wire = joined_to_wire! j, truncate: false
            if @board.max_nbits(j_wire).not_nil! <= old_width
                return JoinedRequest.new_for_wire(j_wire, new_width)
            end
            bits = @board.split(j_wire)
            return SplitRequest.new(new_width) do |i|
                if i < old_width
                    JoinedRequest.new_for_wire(bits[i], width: 1)
                else
                    JoinedRequest.new_for_const(0, width: 1)
                end
            end
        end
    end

    def joined_to_split (j : JoinedRequest) : SplitRequest
        width = j.@width
        if j.constant?
            value = j.@b
            return SplitRequest.new(width) do |i|
                JoinedRequest.new_for_const((value >> i) & 1, width: 1)
            end
        else
            j_wire = joined_to_wire! j, truncate: false
            bits = @board.split(j_wire)
            return SplitRequest.new(width) do |i|
                if i < bits.size
                    JoinedRequest.new_for_wire(bits[i], width: 1)
                else
                    JoinedRequest.new_for_const(0, width: 1)
                end
            end
        end
    end

    # returns {quotient, remainder}
    def joined_divide (j : JoinedRequest, k : JoinedRequest) : {JoinedRequest, JoinedRequest}
        width = common_width! j.@width, k.@width

        if j.constant?
            if j.@b == 0
                return {
                    JoinedRequest.new_for_const(0_u128, width: width),
                    JoinedRequest.new_for_const(0_u128, width: width),
                }
            end
            if k.constant? && k.@b != 0
                return {
                    JoinedRequest.new_for_const(j.@b // k.@b, width: width),
                    JoinedRequest.new_for_const(j.@b % k.@b, width: width),
                }
            end
        end
        if k.constant?
            if k.@b == 1
                return {
                    j,
                    JoinedRequest.new_for_const(0_u128, width: width),
                }
            end
        end

        if j.@a == k.@a && j.@b == k.@b && j.@x == k.@x
            return {
                JoinedRequest.new_for_const(1_u128, width: width),
                JoinedRequest.new_for_const(0_u128, width: width),
            }
        end

        j_wire = joined_to_wire! j
        k_wire = joined_to_wire! k
        q_wire, r_wire = @board.divide(j_wire, k_wire, width: width)
        return {
            JoinedRequest.new_for_wire(q_wire, width: width),
            JoinedRequest.new_for_wire(r_wire, width: width),
        }
    end

    def joined_trunc (j : JoinedRequest, to new_width : Int32) : JoinedRequest
        return JoinedRequest.new(
            a: truncate(j.@a, new_width),
            x: j.@x,
            b: truncate(j.@b, new_width),
            width: new_width)
    end

    def joined_cmp_neq (j : JoinedRequest, k : JoinedRequest) : JoinedRequest
        width = common_width! j.@width, k.@width
        return joined_add(j, k) if width == 1
        if j.constant? && k.constant?
            return JoinedRequest.new_for_const(j.@b != k.@b ? 1_u128 : 0_u128, width: 1)
        end

        j_wire = joined_to_wire! j
        k_wire = joined_to_wire! k
        minus_k_wire = @board.const_mul_neg(
            1,
            k_wire)
        diff = @board.add(
            j_wire,
            minus_k_wire,
            policy: OverflowPolicy.new_set_undef_range)
        result = @board.zerop(diff)
        return JoinedRequest.new_for_wire(result, width: 1)
    end

    def split_to_joined (bits : SplitRequest) : JoinedRequest
        const_summand = 0_u128
        wire_summand : Wire? = nil

        bits.each_with_index do |bit, i|
            if bit.constant?
                const_summand |= bit.@b << i
                next
            end

            bit_wire = @board.const_mul(
                1_u128 << i,
                joined_to_wire!(bit),
                policy: OverflowPolicy.new_cannot_overflow(i + 1))

            if wire_summand
                wire_summand = @board.add(
                    wire_summand,
                    bit_wire,
                    policy: OverflowPolicy.new_cannot_overflow(i + 1))
            else
                wire_summand = bit_wire
            end
        end
        if wire_summand
            return JoinedRequest.new(
                a: 1,
                x: wire_summand,
                b: const_summand,
                width: bits.size)
        else
            return JoinedRequest.new_for_const(const_summand, width: bits.size)
        end
    end

    private def nagai_to_wire! (j : NagaiRequest) : Wire
        if j.is_a? NagaiWire
            j.@wire
        else
            @board.constant_verbatim(j.@value)
        end
    end

    private def safe_bigint? (c : BigInt, accept_negative : Bool = false) : Bool
        limit = BigInt.new(1) << (@board.@p_bits_min - 1)
        if accept_negative
            -limit < c < limit
        else
            0 <= c < limit
        end
    end

    def nagai_create (j : JoinedRequest, negative : Bool) : NagaiRequest
        if j.constant?
            c = BigInt.new(j.@b)
            NagaiConstant.new(negative ? -c : c)
        else
            j_wire = joined_to_wire! j
            if negative
                wire = @board.const_mul_neg(
                    1,
                    j_wire)
                NagaiWire.new(wire)
            else
                NagaiWire.new(j_wire)
            end
        end
    end

    def nagai_create (c : BigInt) : NagaiRequest
        NagaiConstant.new(c)
    end

    private def nagai_cond_wcc (c : Wire, t : BigInt, f : BigInt) : NagaiRequest
        return NagaiConstant.new(f) if t == f
        left_summand = @board.const_mul(t - f, c)
        result = @board.const_add(f, left_summand)
        NagaiWire.new(result)
    end

    def nagai_cond (c : JoinedRequest, t : NagaiRequest, f : NagaiRequest) : NagaiRequest
        if c.constant?
            return (c.@b != 0) ? t : f
        end
        if c.@b != 0
            t, f = f, t
            c = JoinedRequest.new_for_wire(c.@x, width: 1)
        end

        if t.is_a? NagaiWire && f.is_a? NagaiWire && t.@wire == f.@wire
            return f
        end

        c_wire = @board.truncate(c.@x, to: 1)

        if t.is_a? NagaiConstant && f.is_a? NagaiConstant
            return nagai_cond_wcc(c_wire, t.@value, f.@value)
        end

        t_wire = nagai_to_wire! t
        f_wire = nagai_to_wire! f

        minus_f = @board.const_mul_neg(
            1,
            f_wire)
        diff = @board.add(
            t_wire,
            minus_f,
            policy: OverflowPolicy.new_set_undef_range)
        left_summand = @board.mul(
            c_wire,
            diff,
            policy: OverflowPolicy.new_set_undef_range)
        result = @board.add(
            left_summand,
            f_wire,
            policy: OverflowPolicy.new_set_undef_range)
        NagaiWire.new(result)
    end

    private def nagai_add_cc (j : NagaiConstant, k : NagaiConstant) : NagaiRequest?
        a, b = j.@value, k.@value
        sum = a + b
        if a == 0 || b == 0 || safe_bigint?(sum, accept_negative: true)
            NagaiConstant.new(sum)
        end
    end

    private def nagai_add_cw (j : NagaiConstant, k : NagaiRequest) : NagaiRequest?
        k if j.@value == 0
    end

    def nagai_add (j : NagaiRequest, k : NagaiRequest) : NagaiRequest
        case {j, k}
        when {NagaiConstant, NagaiConstant}
            r = nagai_add_cc(j, k)
        when {NagaiConstant, _}
            r = nagai_add_cw(j, k)
        when {_, NagaiConstant}
            r = nagai_add_cw(k, j)
        end

        return r if r

        j_wire = nagai_to_wire! j
        k_wire = nagai_to_wire! k
        NagaiWire.new(@board.add(
            j_wire,
            k_wire,
            policy: OverflowPolicy.new_set_undef_range))
    end

    private def nagai_mul_cc (j : NagaiConstant, k : NagaiConstant) : NagaiRequest
        a, b = j.@value, k.@value
        product = a * b
        if a == 1 || b == 1 || safe_bigint?(product, accept_negative: true)
            NagaiConstant.new(product)
        else
            NagaiWire.new(@board.const_mul(a, @board.constant_verbatim(b)))
        end
    end

    private def nagai_mul_cw (j : NagaiConstant, k : NagaiRequest) : NagaiRequest
        if j.@value == 0
            j
        else
            k_wire = nagai_to_wire! k
            NagaiWire.new(@board.const_mul(j.@value, k_wire))
        end
    end

    def nagai_mul (j : NagaiRequest, k : NagaiRequest) : NagaiRequest
        case {j, k}
        when {NagaiConstant, NagaiConstant}
            nagai_mul_cc(j, k)
        when {NagaiConstant, _}
            nagai_mul_cw(j, k)
        when {_, NagaiConstant}
            nagai_mul_cw(k, j)
        else
            j_wire = nagai_to_wire! j
            k_wire = nagai_to_wire! k
            NagaiWire.new(@board.mul(
                j_wire,
                k_wire,
                policy: OverflowPolicy.new_set_undef_range))
        end
    end

    def nagai_div (j : NagaiRequest, k : NagaiRequest) : NagaiRequest
        if k.is_a? NagaiConstant
            if k.@value == 1 || k.@value == -1
                return nagai_mul(j, k)
            end
        end

        if j.is_a? NagaiConstant
            return j if j.@value == 0
            if k.is_a? NagaiConstant && k.@value != 0
                q, r = j.@value.divmod(k.@value)
                return NagaiConstant.new(q) if r == 0
            end
        end

        if j.is_a? NagaiWire && k.is_a? NagaiWire && j.@wire == k.@wire
            return NagaiConstant.new(BigInt.new(1))
        end

        j_wire = nagai_to_wire! j
        k_wire = nagai_to_wire! k
        NagaiWire.new(@board.div(j_wire, k_wire))
    end

    def nagai_lowbits (j : NagaiRequest) : SplitRequest
        if j.is_a? NagaiConstant && safe_bigint?(j.@value)
            return SplitRequest.new(64) do |i|
                JoinedRequest.new_for_const(
                    j.@value.bit(i).to_u!.to_u128!,
                    width: 1)
            end
        end

        j_wire = nagai_to_wire! j
        bits = @board.split(j_wire)
        SplitRequest.new(64) do |i|
            if i < bits.size
                JoinedRequest.new_for_wire(bits[i], width: 1)
            else
                JoinedRequest.new_for_const(0, width: 1)
            end
        end
    end

    def nagai_nonzero (j : NagaiRequest) : JoinedRequest
        if j.is_a? NagaiConstant && safe_bigint?(j.@value)
            return JoinedRequest.new_for_const(j.@value == 0 ? 0_u128 : 1_u128, width: 1)
        end

        j_wire = nagai_to_wire! j
        JoinedRequest.new_for_wire(
            @board.zerop(j_wire),
            width: 1)
    end

    def nagai_getbit (j : NagaiRequest, pos : UInt128) : NagaiRequest
        if j.is_a? NagaiConstant && safe_bigint?(j.@value)
            return NagaiConstant.new(j.@value.bit(pos))
        end

        j_wire = nagai_to_wire! j
        bits = @board.split(j_wire)
        if pos < bits.size
            NagaiWire.new(bits[pos])
        else
            NagaiConstant.new(BigInt.new(0))
        end
    end

    def nagai_add_output! (j : NagaiRequest) : Nil
        @board.add_output!(nagai_to_wire!(j), nagai: true)
    end
end

end
