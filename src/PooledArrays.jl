module PooledArrays

import DataAPI

export PooledArray, PooledVector, PooledMatrix

# TODO: implement compresspool! and compresspool functions that compresses pool of PooledArray

##############################################################################
##
## PooledArray type definition
##
##############################################################################

const DEFAULT_POOLED_REF_TYPE = UInt32
const DEFAULT_SIGNED_REF_TYPE = Int32

# This is used as a wrapper during PooledArray construction only, to distinguish
# arrays of pool indices from normal arrays
mutable struct RefArray{R}
    a::R
end

function _invert(d::Dict{K,V}) where {K,V}
    d1 = Vector{K}(undef, length(d))
    for (k, v) in d
        d1[v] = k
    end
    return d1
end

mutable struct PooledArray{T, R<:Integer, N, RA} <: AbstractArray{T, N}
    refs::RA
    pool::Vector{T}
    invpool::Dict{T,R}
    refcount::Threads.Atomic{Int}

    function PooledArray(rs::RefArray{RA}, invpool::Dict{T, R},
                         pool::Vector{T}=_invert(invpool),
                         refcount::Threads.Atomic{Int}=Threads.Atomic()) where {T,R,N,RA<:AbstractArray{R, N}}
        # this is a quick but incomplete consistency check
        if length(pool) != length(invpool)
            throw(ArgumentError("inconsistent pool and invpool"))
        end
        # refs mustn't overflow pool
        minref, maxref = extrema(rs.a)
        if length(rs.a) > 0 && (minref < 1 || maxref > length(invpool))
            throw(ArgumentError("Reference array points beyond the end of the pool"))
        end
        pa = new{T,R,N,RA}(rs.a, pool, invpool, refcount)
        finalizer(x -> Threads.atomic_sub!(x.refcount, 1), pa)
        return pa
    end
end
const PooledVector{T,R} = PooledArray{T,R,1}
const PooledMatrix{T,R} = PooledArray{T,R,2}

##############################################################################
##
## PooledArray constructors
##
# Algorithm:
# * Start with:
#   * A null pool
#   * A pre-allocated refs
#   * A hash from T to Int
# * Iterate over d
#   * If value of d in pool already, set the refs accordingly
#   * If value is new, add it to the pool, then set refs
##############################################################################

# Echo inner constructor as an outer constructor
PooledArray(refs::RefArray{R}, invpool::Dict{T,R}, pool::Vector{T}=_invert(invpool),
            refcount::Threads.Atomic{Int}=Threads.Atomic()) where {T,R} =
    PooledArray{T,eltype(R),ndims(R),R}(refs, invpool, pool, refcount)

function PooledArray(d::PooledArray)
    Threads.atomic_add!(d.refcount, 1)
    return PooledArray(RefArray(copy(d.refs.a), d.invpool, d.pool, d.refcount)
end

function _label(xs::AbstractArray,
                ::Type{T}=eltype(xs),
                ::Type{I}=DEFAULT_POOLED_REF_TYPE,
                start = 1,
                labels = Array{I}(undef, size(xs)),
                invpool::Dict{T,I} = Dict{T, I}(),
                pool::Vector{T} = T[],
                nlabels = 0,
               ) where {T, I<:Integer}

    @inbounds for i in start:length(xs)
        x = xs[i]
        lbl = get(invpool, x, zero(I))
        if lbl !== zero(I)
            labels[i] = lbl
        else
            if nlabels == typemax(I)
                I2 = _widen(I)
                return _label(xs, T, I2, i, convert(Vector{I2}, labels),
                              convert(Dict{T, I2}, invpool), pool, nlabels)
            end
            nlabels += 1
            labels[i] = nlabels
            invpool[x] = nlabels
            push!(pool, x)
        end
    end
    labels, invpool, pool
end

_widen(::Type{UInt8}) = UInt16
_widen(::Type{UInt16}) = UInt32
_widen(::Type{UInt32}) = UInt64
_widen(::Type{Int8}) = Int16
_widen(::Type{Int16}) = Int32
_widen(::Type{Int32}) = Int64
# Constructor from array, invpool, and ref type

"""
    PooledArray(array, [reftype]; signed=false, compress=false)

Freshly allocate `PooledArray` using the given array as a source where each
element will be referenced as an integer of the given type.
If no `reftype` is specified one is chosen automatically based on the number of unique elements.
The Boolean keyword arguments, `signed` and `compress` determine the choice of `reftype`.
By default, unsigned integers are used, as they have a greater maxtype than the same size of
signed integer.  However, the Arrow standard at https://arrow.apache.org/, as implemented in
the Arrow package, requires signed integer types, which are provided when `signed` is `true`.
The `compress` argument controls whether the default size of 32 bits is used (`UInt32` for
unsigned, `Int32` for signed) or if smaller integer types are chosen when they can be used.
If `array` is not a `PooledArray` then the order of elements in `refpool` in the resulting
`PooledArray` is the order of first appereance of elements in `array`.

Note that if you hold mutable objects in `PooledArray` it is not allowed to modify them
after they are stored in it.

In order to improve performance of `getindex` and `copyto!` operations `PooledArray`s
may share `pool` and `invpool` fields. This sharing is automatically handled
and is removed for any array sharing common pool if new levels are added to it.

It is not thread safe to use add new levels to `PooledArray` (both for the single
`PooledArray` and in case of several `PooledArrays` sharing a common pool described above).
"""
PooledArray

function PooledArray{T}(d::AbstractArray, r::Type{R}) where {T,R<:Integer}
    refs, invpool, pool = _label(d, T, R)

    if length(invpool) > typemax(R)
        throw(ArgumentError("Cannot construct a PooledArray with type $R with a pool of size $(length(pool))"))
    end

    # Assertions are needed since _label is not type stable
    return PooledArray(RefArray(refs::Vector{R}), invpool::Dict{T,R}, pool, Threads.Atomic())
end

function PooledArray{T}(d::AbstractArray; signed::Bool=false, compress::Bool=false) where {T}
    R = signed ? (compress ? Int8 : DEFAULT_SIGNED_REF_TYPE) : (compress ? UInt8 : DEFAULT_POOLED_REF_TYPE)
    refs, invpool, pool = _label(d, T, R)
    return PooledArray(RefArray(refs), invpool, pool, Threads.Atomic())
end

PooledArray(d::AbstractArray{T}, r::Type) where {T} = PooledArray{T}(d, r)
PooledArray(d::AbstractArray{T}; signed::Bool=false, compress::Bool=false) where {T} =
    PooledArray{T}(d, signed=signed, compress=compress)

# Construct an empty PooledVector of a specific type
PooledArray(t::Type) = PooledArray(Array(t,0))
PooledArray(t::Type, r::Type) = PooledArray(Array(t,0), r)

##############################################################################
##
## Basic interface functions
##
##############################################################################

DataAPI.refarray(pa::PooledArray) = pa.refs
DataAPI.refvalue(pa::PooledArray, i::Integer) = pa.pool[i]
DataAPI.refpool(pa::PooledArray) = pa.pool
DataAPI.invrefpool(pa::PooledArray) = pa.invpool

Base.size(pa::PooledArray) = size(pa.refs)
Base.length(pa::PooledArray) = length(pa.refs)
Base.lastindex(pa::PooledArray) = lastindex(pa.refs)

Base.copy(pa::PooledArray) = PooledArray(pa)

function copyto!(dest::PooledArray{T, R, N, RA}, doffs::Union{Signed, Unsigned,
                 src::PooledArray{T, R, N, RA}, soffs::Union{Signed, Unsigned,
                 n::Union{Signed, Unsigned) where {T, R, N, RA}
    n == 0 && return dest
    n > 0 || Base._throw_argerror()
    if soffs < 1 || doffs < 1 || soffs+n-1 > length(src) || doffs+n-1 > length(dest)
        throw(BoundsError())
    end

    if length(dest.pool) == 0
        @assert length(dest.invpool) == 0
        Threads.atomic_add!(src.refcount, 1)
        dest.pool = src.pool
        dest.invpool = src.invpool
        Threads.atomic_sub!(dest.refcount, 1)
        copyto!(dest.refs, doffs, src.refs, soffs, n)
    elseif dest.pool === src.pool && dest.invpool === src.invpool
        copyto!(dest.refs, doffs, src.refs, soffs, n)
    else
        @inbounds for i in 0:n-1
            dest[dstart+i] = src[sstart+i]
        end
    end
    return dest
end


function Base.resize!(pa::PooledArray{T,R,1}, n::Integer) where {T,R}
    oldn = length(pa.refs)
    resize!(pa.refs, n)
    pa.refs[oldn+1:n] .= zero(R)
    return pa
end

function Base.reverse(x::PooledArray)
    Threads.atomic_add!(x.refcount, 1)
    PooledArray(RefArray(reverse(x.refs)), x.invpool, x.pool, x.refcount)
end

function Base.permute!!(x::PooledArray, p::AbstractVector{T}) where T<:Integer
    Base.permute!!(x.refs, p)
    return x
end

function Base.invpermute!!(x::PooledArray, p::AbstractVector{T}) where T<:Integer
    Base.invpermute!!(x.refs, p)
    return x
end

Base.similar(pa::PooledArray{T,R}, S::Type, dims::Dims) where {T,R} =
    PooledArray(RefArray(zeros(R, dims)), Dict{S,R}())

Base.findall(pdv::PooledVector{Bool}) = findall(convert(Vector{Bool}, pdv))

##############################################################################
##
## map
## Calls `f` only once per pool entry.
##
##############################################################################

function Base.map(f, x::PooledArray{T,R}) where {T,R<:Integer}
    ks = collect(keys(x.invpool))
    vs = collect(values(x.invpool))
    ks1 = map(f, ks)
    uks = Set(ks1)
    if length(uks) < length(ks1)
        # this means some keys have repeated
        newinvpool = Dict{eltype(ks1), eltype(vs)}()
        translate = Dict{eltype(vs), eltype(vs)}()
        i = 1
        for (k, k1) in zip(ks, ks1)
            if haskey(newinvpool, k1)
                translate[x.invpool[k]] = newinvpool[k1]
            else
                newinvpool[k1] = i
                translate[x.invpool[k]] = i
                i+=1
            end
        end
        refarray = map(x->translate[x], x.refs)
    else
        newinvpool = Dict(zip(map(f, ks), vs))
        refarray = copy(x.refs)
    end
    return PooledArray(RefArray(refarray), newinvpool, _invert(newinvpool), Threads.Atomic())
end

##############################################################################
##
## Sorting can use the pool to speed things up
##
##############################################################################

function groupsort_indexer(x::AbstractVector, ngroups::Integer, perm)
    # translated from Wes McKinney's groupsort_indexer in pandas (file: src/groupby.pyx).

    # count group sizes, location 0 for NA
    n = length(x)
    # counts = x.invpool
    counts = fill(0, ngroups + 1)
    @inbounds for i = 1:n
        counts[x[i] + 1] += 1
    end
    counts[2:end] = counts[perm.+1]

    # mark the start of each contiguous group of like-indexed data
    where = fill(1, ngroups + 1)
    @inbounds for i = 2:ngroups+1
        where[i] = where[i - 1] + counts[i - 1]
    end

    # this is our indexer
    result = fill(0, n)
    iperm = invperm(perm)

    @inbounds for i = 1:n
        label = iperm[x[i]] + 1
        result[where[label]] = i
        where[label] += 1
    end
    result, where, counts
end

function Base.sortperm(pa::PooledArray; alg::Base.Sort.Algorithm=Base.Sort.DEFAULT_UNSTABLE,
                       lt::Function=isless, by::Function=identity,
                       rev::Bool=false, order=Base.Sort.Forward,
                       _ord = Base.ord(lt, by, rev, order),
                       poolperm = sortperm(pa.pool, alg=alg, order=_ord))

    groupsort_indexer(pa.refs, length(pa.pool), poolperm)[1]
end

Base.sort(pa::PooledArray; kw...) = pa[sortperm(pa; kw...)]

#type FastPerm{O<:Base.Sort.Ordering,V<:AbstractVector} <: Base.Sort.Ordering
#    ord::O
#    vec::V
#end
#Base.sortperm{V}(x::AbstractVector, a::Base.Sort.Algorithm, o::FastPerm{Base.Sort.ForwardOrdering,V}) = x[sortperm(o.vec)]
#Base.sortperm{V}(x::AbstractVector, a::Base.Sort.Algorithm, o::FastPerm{Base.Sort.ReverseOrdering,V}) = x[reverse(sortperm(o.vec))]
#Perm{O<:Base.Sort.Ordering}(o::O, v::PooledVector) = FastPerm(o, v)

##############################################################################
##
## conversions
##
##############################################################################

function Base.convert(::Type{PooledArray{S,R1,N}}, pa::PooledArray{T,R2,N}) where {S,T,R1<:Integer,R2<:Integer,N}
    if S === R && R1 === R2
        return pa
    else
        refs_conv = convert(Array{R1,N}, pa.refs)
        @assert refs_conv !== pa.refs
        invpool_conv = convert(Dict{S,R}, pa.invpool)
        @assert invpool_conv !== pa.invpool
        return PooledArray(RefArray(refs_conv), invpool_conv)
    end
end

function Base.convert(::Type{PooledArray{S,R,N}}, pa::PooledArray{T,R,N}) where {S,T,R<:Integer,N}
    if S === R
        return pa
    else
        invpool_conv = convert(Dict{S,R}, pa.invpool)
        @assert invpool_conv !== pa.invpool
        return PooledArray(RefArray(copy(pa.refs)), invpool_conv)
    end
end

Base.convert(::Type{PooledArray{T,R,N}}, pa::PooledArray{T,R,N}) where {T,R<:Integer,N} = pa
Base.convert(::Type{PooledArray{S,R1}}, pa::PooledArray{T,R2,N}) where {S,T,R1<:Integer,R2<:Integer,N} =
    convert(PooledArray{S,R1,N}, pa)
Base.convert(::Type{PooledArray{S}}, pa::PooledArray{T,R,N}) where {S,T,R<:Integer,N} =
    convert(PooledArray{S,R,N}, pa)
Base.convert(::Type{PooledArray}, pa::PooledArray{T,R,N}) where {T,R<:Integer,N} = pa

Base.convert(::Type{PooledArray{S,R,N}}, a::AbstractArray{T,N}) where {S,T,R<:Integer,N} =
    PooledArray(convert(Array{S,N}, a), R)
Base.convert(::Type{PooledArray{S,R}}, a::AbstractArray{T,N}) where {S,T,R<:Integer,N} =
    PooledArray(convert(Array{S,N}, a), R)
Base.convert(::Type{PooledArray{S}}, a::AbstractArray{T,N}) where {S,T,N} =
    PooledArray(convert(Array{S,N}, a))
Base.convert(::Type{PooledArray}, a::AbstractArray) =
    PooledArray(a)

function Base.convert(::Type{Array{S, N}}, pa::PooledArray{T, R, N}) where {S, T, R, N}
    res = Array{S}(undef, size(pa))
    for i in 1:length(pa)
        if pa.refs[i] != 0
            res[i] = pa.pool[pa.refs[i]]
        end
    end
    return res
end

Base.convert(::Type{Vector}, pv::PooledVector{T, R}) where {T, R} = convert(Array{T, 1}, pv)

Base.convert(::Type{Matrix}, pm::PooledMatrix{T, R}) where {T, R} = convert(Array{T, 2}, pm)

Base.convert(::Type{Array}, pa::PooledArray{T, R, N}) where {T, R, N} = convert(Array{T, N}, pa)

##############################################################################
##
## indexing
##
##############################################################################

# Scalar case
Base.@propagate_inbounds function Base.getindex(pa::PooledArray, I::Integer...)
    idx = pa.refs[I...]
    iszero(idx) && throw(UndefRefError())
    return @inbounds pa.pool[idx]
end

Base.@propagate_inbounds function Base.isassigned(pa::PooledArray, I::Int...)
    !iszero(pa.refs[I...])
end

# Vector case
function Base.@propagate_inbounds Base.getindex(A::PooledArray, I::Union{Real,AbstractVector}...)
    Threads.atomic_add!(A.refcount, 1)
    return PooledArray(RefArray(getindex(A.refs, I...)), A.invpool, A.pool, A.refcount)
end

# Dispatch our implementation for these cases instead of Base
function Base.@propagate_inbounds Base.getindex(A::PooledArray, I::AbstractVector)
    Threads.atomic_add!(A.refcount, 1)
    return PooledArray(RefArray(getindex(A.refs, I)), A.invpool, A.pool, A.refcount)
end

function Base.@propagate_inbounds Base.getindex(A::PooledArray, I::AbstractArray)
        Threads.atomic_add!(A.refcount, 1)

    return PooledArray(RefArray(getindex(A.refs, I)), A.invpool, A.pool, A.refcount)
end

##############################################################################
##
## setindex!() definitions
##
##############################################################################

function getpoolidx(pa::PooledArray{T,R}, val::Any) where {T,R}
    val::T = convert(T,val)
    pool_idx = get(pa.invpool, val, zero(R))
    if pool_idx == zero(R)
        pool_idx = unsafe_pool_push!(pa, val)
    end
    return pool_idx
end

function unsafe_pool_push!(pa::PooledArray{T,R}, val) where {T,R}
    # Warning - unsafe_pool_push! may not be used in any multithreaded context
    _pool_idx = length(pa.pool) + 1
    if _pool_idx > typemax(R)
        throw(ErrorException(string(
            "You're using a PooledArray with ref type $R, which can only hold $(Int(typemax(R))) values,\n",
            "and you just tried to add the $(typemax(R)+1)th reference.  Please change the ref type\n",
            "to a larger int type, or use the default ref type ($DEFAULT_POOLED_REF_TYPE)."
           )))
    end
    pool_idx = convert(R, _pool_idx)
    if pa.refcount[] > 0
        pa.invpool = copy(pa.invpool)
        pa.pool = copy(pa.pool)
        Threads.atomic_sub!(pa.refcount, 1)
        pa.refcount = Threads.Atomic()
    end
    pa.invpool[val] = pool_idx
    push!(pa.pool, val)
    pool_idx
end

Base.@propagate_inbounds function Base.setindex!(x::PooledArray, val, ind::Integer)
    x.refs[ind] = getpoolidx(x, val)
    return x
end

##############################################################################
##
## growing and shrinking
##
##############################################################################

function Base.push!(pv::PooledVector{S,R}, v::T) where {S,R,T}
    push!(pv.refs, getpoolidx(pv, v))
    return pv
end

function Base.append!(pv::PooledVector, items::AbstractArray)
    itemindices = eachindex(items)
    l = length(pv)
    n = length(itemindices)
    resize!(pv.refs, l+n)
    copyto!(pv, l+1, items, first(itemindices), n)
    return pv
end

Base.pop!(pv::PooledVector) = pv.invpool[pop!(pv.refs)]

function Base.pushfirst!(pv::PooledVector{S,R}, v::T) where {S,R,T}
    pushfirst!(pv.refs, getpoolidx(pv, v))
    return pv
end

Base.popfirst!(pv::PooledVector) = pv.invpool[popfirst!(pv.refs)]

Base.empty!(pv::PooledVector) = (empty!(pv.refs); pv)

Base.deleteat!(pv::PooledVector, inds) = (deleteat!(pv.refs, inds); pv)

function _vcat!(c, a, b)
    copyto!(c, 1, a, 1, length(a))
    return copyto!(c, length(a)+1, b, 1, length(b))
end

function Base.vcat(a::PooledArray{<:Any, <:Integer, 1}, b::AbstractArray{<:Any, 1})
    output = similar(b, promote_type(eltype(a), eltype(b)), length(b) + length(a))
    return _vcat!(output, a, b)
end

function Base.vcat(a::AbstractArray{<:Any, 1}, b::PooledArray{<:Any, <:Integer, 1})
    output = similar(a, promote_type(eltype(a), eltype(b)), length(b) + length(a))
    return _vcat!(output, a, b)
end

function Base.vcat(a::PooledArray{T, <:Integer, 1}, b::PooledArray{S, <:Integer, 1}) where {T, S}
    ap = a.invpool
    bp = b.invpool

    U = promote_type(T,S)

    poolmap = Dict{Int, Int}()
    l = length(ap)
    newlabels = Dict{U, Int}(ap)
    for (x, i) in bp
        j = if x in keys(ap)
            poolmap[i] = ap[x]
        else
            poolmap[i] = (l+=1)
        end
        newlabels[x] = j
    end
    types = [UInt8, UInt16, UInt32, UInt64]
    tidx = findfirst(t->l < typemax(t), types)
    refT = types[tidx]
    refs2 = map(r->convert(refT, poolmap[r]), b.refs)
    newrefs = Base.typed_vcat(refT, a.refs, refs2)
    return PooledArray(RefArray(newrefs), convert(Dict{U, refT}, newlabels))
end

fast_sortable(y::PooledArray) = _fast_sortable(y)
fast_sortable(y::PooledArray{T}) where {T<:Integer} = isbitstype(T) ? y : _fast_sortable(y)

function _fast_sortable(y::PooledArray)
    poolranks = invperm(sortperm(y.pool))
    newpool = Dict(j=>convert(eltype(y.refs), i) for (i,j) in enumerate(poolranks))
    PooledArray(RefArray(y.refs), newpool)
end

_perm(o::F, z::V) where {F, V} = Base.Order.Perm{F, V}(o, z)

Base.Order.Perm(o::Base.Order.ForwardOrdering, y::PooledArray) = _perm(o, fast_sortable(y))

end
