# This file contains code that was formerly a part of Julia. License is MIT: http://julialang.org/license

using Base.MPFR: ROUNDING_MODE, big_ln2

const ComplexOrReal{T} = Union{T,Complex{T}}

# Bernoulli numbers B_{2k}, using tabulated numerators and denominators from
# the online encyclopedia of integer sequences.  (They actually have data
# up to k=249, but we stop here at k=20.)  Used for generating the polygamma
# (Stirling series) coefficients below.
#   const A000367 = map(BigInt, split("1,1,-1,1,-1,5,-691,7,-3617,43867,-174611,854513,-236364091,8553103,-23749461029,8615841276005,-7709321041217,2577687858367,-26315271553053477373,2929993913841559,-261082718496449122051", ","))
#   const A002445 = [1,6,30,42,30,66,2730,6,510,798,330,138,2730,6,870,14322,510,6,1919190,6,13530]
#   const bernoulli = A000367 .// A002445 # even-index Bernoulli numbers

"""
    digamma(x)

Compute the digamma function of `x` (the logarithmic derivative of `gamma(x)`).
"""
function digamma(z::ComplexOrReal{Float64})
    # Based on eq. (12), without looking at the accompanying source
    # code, of: K. S. Kölbig, "Programs for computing the logarithm of
    # the gamma function, and the digamma function, for complex
    # argument," Computer Phys. Commun.  vol. 4, pp. 221–226 (1972).
    x = real(z)
    if x <= 0 # reflection formula
        ψ = -π * cot(π*z)
        z = 1 - z
        x = real(z)
    else
        ψ = zero(z)
    end
    if x < 7
        # shift using recurrence formula
        n = 7 - floor(Int,x)
        for ν = 1:n-1
            ψ -= inv(z + ν)
        end
        ψ -= inv(z)
        z += n
    end
    t = inv(z)
    ψ += log(z) - 0.5*t
    t *= t # 1/z^2
    # the coefficients here are Float64(bernoulli[2:9] .// (2*(1:8)))
    ψ -= t * @evalpoly(t,0.08333333333333333,-0.008333333333333333,0.003968253968253968,-0.004166666666666667,0.007575757575757576,-0.021092796092796094,0.08333333333333333,-0.4432598039215686)
end

function digamma(x::BigFloat)
    z = BigFloat()
    ccall((:mpfr_digamma, :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}, Int32), z, x, ROUNDING_MODE[])
    return z
end

"""
    trigamma(x)

Compute the trigamma function of `x` (the logarithmic second derivative of `gamma(x)`).
"""
function trigamma(z::ComplexOrReal{Float64})
    # via the derivative of the Kölbig digamma formulation
    x = real(z)
    if x <= 0 # reflection formula
        return (π * csc(π*z))^2 - trigamma(1 - z)
    end
    ψ = zero(z)
    if x < 8
        # shift using recurrence formula
        n = 8 - floor(Int,x)
        ψ += inv(z)^2
        for ν = 1:n-1
            ψ += inv(z + ν)^2
        end
        z += n
    end
    t = inv(z)
    w = t * t # 1/z^2
    ψ += t + 0.5*w
    # the coefficients here are Float64(bernoulli[2:9])
    ψ += t*w * @evalpoly(w,0.16666666666666666,-0.03333333333333333,0.023809523809523808,-0.03333333333333333,0.07575757575757576,-0.2531135531135531,1.1666666666666667,-7.092156862745098)
end

signflip(m::Number, z) = (-1+0im)^m * z
signflip(m::Integer, z) = iseven(m) ? z : -z

# (-1)^m d^m/dz^m cot(z) = p_m(cot z), where p_m is a polynomial
# that satisfies the recurrence p_{m+1}(x) = p_m′(x) * (1 + x^2).
# Note that p_m(x) has only even powers of x if m is odd, and
# only odd powers of x if m is even.  Therefore, we write p_m(x)
# as p_m(x) = q_m(x^2) m! for m odd and p_m(x) = x q_m(x^2) m! if m is even.
# Hence the polynomials q_m(y) satisfy the recurrence:
#     m odd:  q_{m+1}(y) = 2 q_m′(y) * (1+y) / (m+1)
#    m even:  q_{m+1}(y) = [q_m(y) + 2 y q_m′(y)] * (1+y) / (m+1)
# This function computes the coefficients of the polynomial q_m(y),
# returning an array of the coefficients of 1, y, y^2, ...,
function cotderiv_q(m::Int)
    m < 0 && throw(DomainError(m, "`m` must be nonnegative."))
    m == 0 && return [1.0]
    m == 1 && return [1.0, 1.0]
    q₋ = cotderiv_q(m-1)
    d = length(q₋) - 1 # degree of q₋
    if isodd(m-1)
        q = Vector{Float64}(undef, length(q₋))
        q[end] = d * q₋[end] * 2/m
        for i = 1:length(q)-1
            q[i] = ((i-1)*q₋[i] + i*q₋[i+1]) * 2/m
        end
    else # iseven(m-1)
        q = Vector{Float64}(undef, length(q₋) + 1)
        q[1] = q₋[1] / m
        q[end] = (1 + 2d) * q₋[end] / m
        for i = 2:length(q)-1
            q[i] = ((1 + 2(i-1))*q₋[i] + (1 + 2(i-2))*q₋[i-1]) / m
        end
    end
    return q
end

# precompute a table of cot derivative polynomials
const cotderiv_Q = [cotderiv_q(m) for m in 1:100]

# Evaluate (-1)^m d^m/dz^m [π cot(πz)] / m!.  If m is small, we
# use the explicit derivative formula (a polynomial in cot(πz));
# if m is large, we use the derivative of Euler's harmonic series:
#          π cot(πz) = ∑ inv(z + n)
function cotderiv(m::Integer, z)
    isinf(imag(z)) && return zero(z)
    if m <= 0
        m == 0 && return π * cot(π*z)
        throw(DomainError(m, "`m` must be nonnegative."))
    end
    if m <= length(cotderiv_Q)
        q = cotderiv_Q[m]
        x = cot(π*z)
        y = x*x
        s = q[1] + q[2] * y
        t = y
        # evaluate q(y) using Horner (TODO: Knuth for complex z?)
        for i = 3:length(q)
            t *= y
            s += q[i] * t
        end
        return π^(m+1) * (isodd(m) ? s : x*s)
    else # m is large, series derivative should converge quickly
        p = m+1
        z -= round(real(z))
        s = inv(z^p)
        n = 1
        sₒ = zero(s)
        while s != sₒ
            sₒ = s
            a = (z+n)^p
            b = (z-n)^p
            s += (a + b) / (a * b)
            n += 1
        end
        return s
    end
end

# Helper macro for polygamma(m, z):
#   Evaluate p[1]*c[1] + x*p[2]*c[2] + x^2*p[3]*c[3] + ...
#   where c[1] = m + 1
#         c[k] = c[k-1] * (2k+m-1)*(2k+m-2) / ((2k-1)*(2k-2)) = c[k-1] * d[k]
#         i.e. d[k] = c[k]/c[k-1] = (2k+m-1)*(2k+m-2) / ((2k-1)*(2k-2))
#   by a modified version of Horner's rule:
#      c[1] * (p[1] + d[2]*x * (p[2] + d[3]*x * (p[3] + ...))).
# The entries of p must be literal constants and there must be > 1 of them.
macro pg_horner(x, m, p...)
    k = length(p)
    me = esc(m)
    xe = esc(x)
    ex = :(($me + $(2k-1)) * ($me + $(2k-2)) * $(p[end]/((2k-1)*(2k-2))))
    for k = length(p)-1:-1:2
        cdiv = 1 / ((2k-1)*(2k-2))
        ex = :(($cdiv * ($me + $(2k-1)) * ($me + $(2k-2))) *
               ($(p[k]) + $xe * $ex))
    end
    :(($me + 1) * ($(p[1]) + $xe * $ex))
end

# compute oftype(x, y)^p efficiently, choosing the correct branch cut
pow_oftype(x, y, p) = oftype(x, y)^p
pow_oftype(x::Complex, y::Real, p::Complex) = oftype(x, y^p)
function pow_oftype(x::Complex, y::Real, p::Real)
    if p >= 0
        # note: this will never be called for y < 0,
        # which would throw an error for non-integer p here
        return oftype(x, y^p)
    else
        yp = y^-p # use real power for efficiency
        return oftype(x, Complex(yp, -zero(yp))) # get correct sign of zero!
    end
end

# Generalized zeta function, which is related to polygamma
# (at least for integer m > 0 and real(z) > 0) by:
#    polygamma(m, z) = (-1)^(m+1) * gamma(m+1) * zeta(m+1, z).
# Our algorithm for the polygamma is just the m-th derivative
# of our digamma approximation, and this derivative process yields
# a function of the form
#          (-1)^(m) * gamma(m+1) * (something)
# So identifying the (something) with the -zeta function, we get
# the zeta function for free and might as well export it, especially
# since this is a common generalization of the Riemann zeta function
# (which Julia already exports).   Note that this geneneralization
# is equivalent to Mathematica's Zeta[s,z], and is equivalent to the
# Hurwitz zeta function for real(z) > 0.

"""
    zeta(s, z)

Generalized zeta function ``\\zeta(s, z)``, defined
by the sum ``\\sum_{k=0}^\\infty ((k+z)^2)^{-s/2}``, where
any term with ``k+z=0`` is excluded.  For ``\\Re z > 0``,
this definition is equivalent to the Hurwitz zeta function
``\\sum_{k=0}^\\infty (k+z)^{-s}``.   For ``z=1``, it yields
the Riemann zeta function ``\\zeta(s)``.
"""
function zeta(s::ComplexOrReal{Float64}, z::ComplexOrReal{Float64})
    ζ = zero(promote_type(typeof(s), typeof(z)))

    (z == 1 || z == 0) && return oftype(ζ, zeta(s))
    s == 2 && return oftype(ζ, trigamma(z))

    x = real(z)

    # annoying s = Inf or NaN cases:
    if !isfinite(s)
        (isnan(s) || isnan(z)) && return (s*z)^2 # type-stable NaN+Nan*im
        if real(s) == Inf
            z == 1 && return one(ζ)
            if x > 1 || (x >= 0.5 ? abs(z) > 1 : abs(z - round(x)) > 1)
                return zero(ζ) # distance to poles is > 1
            end
            x > 0 && imag(z) == 0 && imag(s) == 0 && return oftype(ζ, Inf)
        end
        throw(DomainError(s, "`s` must be finite."))  # nothing clever to return
    end
    if isnan(x)
        if imag(z) == 0 && imag(s) == 0
            return oftype(ζ, x)
        else
            return oftype(ζ, Complex(x,x))
        end
    end

    m = s - 1

    # Algorithm is just the m-th derivative of digamma formula above,
    # with a modified cutoff of the final asymptotic expansion.

    # Note: we multiply by -(-1)^m m! in polygamma below, so this factor is
    #       pulled out of all of our derivatives.

    cutoff = 7 + real(m) + abs(imag(m)) # TODO: this cutoff is too conservative?
    if x < cutoff
        # shift using recurrence formula
        xf = floor(x)
        nx = Int(xf)
        n = ceil(Int, cutoff - nx)
        minus_s = -s
        if nx < 0 # x < 0
            # need to use (-z)^(-s) recurrence to be correct for real z < 0
            # [the general form of the recurrence term is (z^2)^(-s/2)]
            minus_z = -z
            ζ += pow_oftype(ζ, minus_z, minus_s) # ν = 0 term
            if xf != z
                ζ += pow_oftype(ζ, z - nx, minus_s)
                # real(z - nx) > 0, so use correct branch cut
                # otherwise, if xf==z, then the definition skips this term
            end
            # do loop in different order, depending on the sign of s,
            # so that we are looping from largest to smallest summands and
            # can halt the loop early if possible; see issue #15946
            # FIXME: still slow for small m, large Im(z)
            if real(s) > 0
                for ν in -nx-1:-1:1
                    ζₒ= ζ
                    ζ += pow_oftype(ζ, minus_z - ν, minus_s)
                    ζ == ζₒ && break # prevent long loop for large -x > 0
                end
            else
                for ν in 1:-nx-1
                    ζₒ= ζ
                    ζ += pow_oftype(ζ, minus_z - ν, minus_s)
                    ζ == ζₒ && break # prevent long loop for large -x > 0
                end
            end
        else # x ≥ 0 && z != 0
            ζ += pow_oftype(ζ, z, minus_s)
        end
        # loop order depends on sign of s, as above
        if real(s) > 0
            for ν in max(1,1-nx):n-1
                ζₒ= ζ
                ζ += pow_oftype(ζ, z + ν, minus_s)
                ζ == ζₒ && break # prevent long loop for large m
            end
        else
            for ν in n-1:-1:max(1,1-nx)
                ζₒ= ζ
                ζ += pow_oftype(ζ, z + ν, minus_s)
                ζ == ζₒ && break # prevent long loop for large m
            end
        end
        z += n
    end

    t = inv(z)
    w = isa(t, Real) ? conj(oftype(ζ, t))^m : oftype(ζ, t)^m
    ζ += w * (inv(m) + 0.5*t)

    t *= t # 1/z^2
    ζ += w*t * @pg_horner(t,m,0.08333333333333333,-0.008333333333333333,0.003968253968253968,-0.004166666666666667,0.007575757575757576,-0.021092796092796094,0.08333333333333333,-0.4432598039215686,3.0539543302701198)

    return ζ
end

"""
    polygamma(m, x)

Compute the polygamma function of order `m` of argument `x` (the `(m+1)`th derivative of the
logarithm of `gamma(x)`)
"""
function polygamma(m::Integer, z::ComplexOrReal{Float64})
    m == 0 && return digamma(z)
    m == 1 && return trigamma(z)

    # In principle, we could support non-integer m here, but the
    # extension to complex m seems to be non-unique, the obvious
    # extension (just plugging in a complex m below) does not seem to
    # be the one used by Mathematica or Maple, and sources do not
    # agree on what the "right" extension is (e.g. Mathematica & Maple
    # disagree).   So, at least for now, we require integer m.

    # real(m) < 0 is valid, but I don't think our asymptotic expansion
    # here works in this case.  m < 0 polygamma is called a
    # "negapolygamma" function in the literature, and there are
    # multiple possible definitions arising from different integration
    # constants. We throw a DomainError since the definition is unclear.
    real(m) < 0 && throw(DomainError(m, "`real(m)` must be nonnegative, since the definition in this case is ambiguous."))

    s = Float64(m+1)
    # It is safe to convert any integer (including `BigInt`) to a float here
    # as underflow occurs before precision issues.
    if real(z) <= 0 # reflection formula
        (zeta(s, 1-z) + signflip(m, cotderiv(m,z))) * (-gamma(s))
    else
        signflip(m, zeta(s,z) * (-gamma(s)))
    end
end

"""
    invdigamma(x)

Compute the inverse [`digamma`](@ref) function of `x`.
"""
function invdigamma(y::Float64)
    # Implementation of fixed point algorithm described in
    # "Estimating a Dirichlet distribution" by Thomas P. Minka, 2000

    # Closed form initial estimates
    if y >= -2.22
        x_old = exp(y) + 0.5
        x_new = x_old
    else
        x_old = -1.0 / (y - digamma(1.0))
        x_new = x_old
    end

    # Fixed point algorithm
    delta = Inf
    iteration = 0
    while delta > 1e-12 && iteration < 25
        iteration += 1
        x_new = x_old - (digamma(x_old) - y) / trigamma(x_old)
        delta = abs(x_new - x_old)
        x_old = x_new
    end

    return x_new
end

"""
    zeta(s)

Riemann zeta function ``\\zeta(s)``.
"""
function zeta(s::ComplexOrReal{Float64})
    # Riemann zeta function; algorithm is based on specializing the Hurwitz
    # zeta function above for z==1.

    # blows up to ±Inf, but get correct sign of imaginary zero
    s == 1 && return NaN + zero(s) * imag(s)

    if !isfinite(s) # annoying NaN and Inf cases
        isnan(s) && return imag(s) == 0 ? s : s*s
        if isfinite(imag(s))
            real(s) > 0 && return 1.0 - zero(s)*imag(s)
            imag(s) == 0 && return NaN + zero(s)
        end
        return NaN*zero(s) # NaN + NaN*im
    elseif real(s) < 0.5
        if abs(real(s)) + abs(imag(s)) < 1e-3 # Taylor series for small |s|
            return @evalpoly(s, -0.5,
                             -0.918938533204672741780329736405617639861,
                             -1.0031782279542924256050500133649802190,
                             -1.00078519447704240796017680222772921424,
                             -0.9998792995005711649578008136558752359121)
        end
        return zeta(1 - s) * gamma(1 - s) * sinpi(s*0.5) * (2π)^s / π
    end

    m = s - 1

    # shift using recurrence formula:
    #   n is a semi-empirical cutoff for the Stirling series, based
    #   on the error term ~ (|m|/n)^18 / n^real(m)
    n = ceil(Int,6 + 0.7*abs(imag(s-1))^inv(1 + real(m)*0.05))
    ζ = one(s)
    for ν = 2:n
        ζₒ= ζ
        ζ += inv(ν)^s
        ζ == ζₒ && break # prevent long loop for large m
    end
    z = 1 + n
    t = inv(z)
    w = t^m
    ζ += w * (inv(m) + 0.5*t)

    t *= t # 1/z^2
    ζ += w*t * @pg_horner(t,m,0.08333333333333333,-0.008333333333333333,0.003968253968253968,-0.004166666666666667,0.007575757575757576,-0.021092796092796094,0.08333333333333333,-0.4432598039215686,3.0539543302701198)

    return ζ
end

function zeta(x::BigFloat)
    z = BigFloat()
    ccall((:mpfr_zeta, :libmpfr), Int32, (Ref{BigFloat}, Ref{BigFloat}, Int32), z, x, ROUNDING_MODE[])
    return z
end

"""
    eta(x)

Dirichlet eta function ``\\eta(s) = \\sum^\\infty_{n=1}(-1)^{n-1}/n^{s}``.
"""
function eta(z::ComplexOrReal{Float64})
    δz = 1 - z
    if abs(real(δz)) + abs(imag(δz)) < 7e-3 # Taylor expand around z==1
        return 0.6931471805599453094172321214581765 *
               @evalpoly(δz,
                         1.0,
                         -0.23064207462156020589789602935331414700440,
                         -0.047156357547388879740146103148112380421254,
                         -0.002263576552598880778433550956278702759143568,
                         0.001081837223249910136105931217561387128141157)
    else
        return -zeta(z) * expm1(0.6931471805599453094172321214581765*δz)
    end
end

function eta(x::BigFloat)
    x == 1 && return big_ln2()
    return -zeta(x) * expm1(big_ln2()*(1-x))
end

# Converting types that we can convert, and not ones we can not
# Float16, and Float32 and their Complex equivalents can be converted to Float64
# and results converted back.
# Otherwise, we need to make things use their own `float` converting methods
# and in those cases, we do not convert back either as we assume
# they also implement their own versions of the functions, with the correct return types.
# This is the case for BitIntegers (which become `Float64` when `float`ed).
# Otherwise, if they do not implement their version of the functions we
# manually throw a `MethodError`.
# This case occurs, when calling `float` on a type does not change its type,
# as it is already a `float`, and would have hit own method, if one had existed.


# If we really cared about single precision, we could make a faster
# Float32 version by truncating the Stirling series at a smaller cutoff.
# and if we really cared about half precision, we could make a faster
# Float16 version, by using a precomputed table look-up.


for T in (Float16, Float32, Float64)
    @eval f64(x::Complex{$T}) = Complex{Float64}(x)
    @eval f64(x::$T) = Float64(x)
end


for f in (:digamma, :trigamma, :zeta, :eta, :invdigamma)
    @eval begin
        function $f(z::Union{ComplexOrReal{Float16}, ComplexOrReal{Float32}})
            oftype(z, $f(f64(z)))
        end

        function $f(z::Number)
            x = float(z)
            typeof(x) === typeof(z) && throw(MethodError($f, (z,)))
            # There is nothing to fallback to, as this didn't change the argument types
            $f(x)
        end
    end
end


for T1 in (Float16, Float32, Float64), T2 in (Float16, Float32, Float64)
    (T1 == T2 == Float64) && continue # Avoid redefining base definition

    @eval function zeta(s::ComplexOrReal{$T1}, z::ComplexOrReal{$T2})
        ζ = zeta(f64(s), f64(z))
        convert(promote_type(typeof(s), typeof(z)),  ζ)
    end
end


function zeta(s::Number, z::Number)
    t = float(s)
    x = float(z)
    if typeof(t) === typeof(s) && typeof(x) === typeof(z)
        # There is nothing to fallback to, since this didn't work
        throw(MethodError(zeta,(s,z)))
    end
    zeta(t, x)
end


function polygamma(m::Integer, z::Union{ComplexOrReal{Float16}, ComplexOrReal{Float32}})
    oftype(z, polygamma(m, f64(z)))
end


function polygamma(m::Integer, z::Number)
    x = float(z)
    typeof(x) === typeof(z) && throw(MethodError(polygamma, (m,z)))
    # There is nothing to fallback to, since this didn't work
    polygamma(m, x)
end
