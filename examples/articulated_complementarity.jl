module Complementarity

using Polyhedra
using StaticArrays
using JuMP, ConditionalJuMP, Cbc
using Base.Test

rot2(θ) = SMatrix{2, 2}(cos(θ), -sin(θ), sin(θ), cos(θ))

struct Obstacle{N, T, H <: HRepresentation{N, T}}
    interior::H
    contact_face::HalfSpace{N, T}
end

struct Environment{N, T, H1 <: HRepresentation{N, T}, H2 <: HRepresentation{N, T}}
    obstacles::Vector{Obstacle{N, T, H1}}
    free_regions::Vector{H2}
end

function contact_basis(face::HalfSpace{2})
    θ = atan(μ)
    R = rot2(θ)
    hcat(R * face.a, R' * face.a)
end


contact_basis(obs::Obstacle) = contact_basis(obs.contact_face)

function ConditionalJuMP.Conditional(op::typeof(in), x::AbstractVector, P::HRepresentation)
    ConditionalJuMP.Conditional(&, [@?(P.A[i, :]' * x <= P.b[i]) for i in 1:length(P)]...)
end


# A simple complementarity-based time-stepping rigid body simulation. All
# notation is taken from Stewart & Trinkle "An Implicit Time-Stepping Scheme for
# Rigid Body Dynamics with Coulomb Friction".

const h = 0.05
const μ = 0.5
const n = [0, 1]
const mass = 1.0
const g = [0, -9.81]
const min_leg_len = 0.5
const max_leg_len = 1.5

struct ContactResult{T, Tf}
    β::Vector{T}
    λ::T
    c_n::T
    contact_force::Tf
end

JuMP.getvalue(c::ContactResult) = ContactResult(getvalue.((c.β, c.λ, c.c_n, c.contact_force))...)
function JuMP.setvalue(contact::ContactResult{<:JuMP.AbstractJuMPScalar}, seed::ContactResult{<:Number})
    setvalue(contact.β, seed.β)
    setvalue(contact.λ, seed.λ)
    setvalue(contact.c_n, seed.c_n)
    @assert getvalue(contact.contact_force) ≈ seed.contact_force
end


struct JointLimitResult{T, Tf <: AbstractVector}
    λ::T
    generalized_force::Tf
end

JuMP.getvalue(r::JointLimitResult) = JointLimitResult(getvalue.((r.λ, r.generalized_force))...)
function JuMP.setvalue(r::JointLimitResult{<:JuMP.AbstractJuMPScalar}, seed::JointLimitResult{<:Number})
    setvalue(r.λ, seed.λ)
    @assert getvalue(r.generalized_force) ≈ seed.generalized_force
end

struct LCPUpdate{T, Tf}
    q::Vector{T}
    v::Vector{T}
    contacts::Vector{ContactResult{T, Tf}}
    joint_contacts::Vector{JointLimitResult{T, Tf}}
end

JuMP.getvalue(up::LCPUpdate) =
    LCPUpdate(getvalue.((up.q, up.v))..., getvalue.(up.contacts), getvalue.(up.joint_contacts))
function JuMP.setvalue(up::LCPUpdate{<:JuMP.AbstractJuMPScalar}, seed::LCPUpdate{<:Number})
    setvalue(up.q, seed.q)
    setvalue(up.v, seed.v)
    setvalue.(up.contacts, seed.contacts)
    setvalue.(up.joint_contacts, seed.joint_contacts)
end

function leg_position_in_world(q)
    q[1:2] + [0, -1] * q[3]
end

function leg_velocity_in_world(v)
    v[1:2] + [0, -1] * v[3]
end

function contact_force(qnext, vnext, obstacle::Obstacle, model::Model)
    n = obstacle.contact_face.a
    D = contact_basis(obstacle)
    k = size(D, 2)

    β = @variable(model,   [1:k], lowerbound=0,   basename="β",     upperbound=100)
    λ = @variable(model,          lowerbound=0,   basename="λ",     upperbound=100)
    c_n = @variable(model,        lowerbound=0,   basename="c_n",   upperbound=100)

    separation = n' * leg_position_in_world(qnext) - obstacle.contact_face.β
    contact_velocity = leg_velocity_in_world(vnext)

    @constraints model begin
        λ .+ D' * contact_velocity .>= 0 # (8)
        μ * c_n .- sum(β) >= 0 # (9)
    end

    @disjunction(model, (separation == 0), (c_n == 0)) # (10)
    Dtv = D' * contact_velocity
    for j in 1:k
        @disjunction(model, ((λ + Dtv[j]) == 0), β[j] == 0) # (11)
    end
    @disjunction(model, (μ * c_n - sum(β) == 0), (λ == 0)) # (12)

    contact_force = c_n * n .+ D * β
    ContactResult(β, λ, c_n, contact_force)
end

function joint_limit(qnext, vnext, a::AbstractVector, b::Number, model::Model)
    λ = @variable(model, lowerbound=0, upperbound=100, basename="λ")
    separation = a' * qnext - b
    @constraint model separation <= 0
    @disjunction(model, separation == 0, λ == 0)

    JointLimitResult(λ, -λ * a)
end

function join_limits(qnext, vnext, limits::SimpleHRepresentation, model::Model)
    [joint_limit(qnext, vnext, limits.A[i, :], limits.b[i], model) for i in 1:length(limits)]
end

function update(q, v, u, env::Environment, model::Model)
    qnext = @variable(model, [1:length(q)], lowerbound=-10, basename="qnext", upperbound=10)
    vnext = @variable(model, [1:length(v)], lowerbound=-10, basename="vnext", upperbound=10)

    contacts = [contact_force(qnext, vnext, obs, model) for obs in env.obstacles]
    external_force = sum([c.contact_force for c in contacts])

    join_limit_results = join_limits(qnext, vnext, SimpleHRepresentation([0. 0 1; 0 0 -1], [1.5, -0.5]), model)

    internal_force = u + sum([r.generalized_force[3] for r in join_limit_results])

    @constraints model begin
        mass * (vnext[1:2] - v[1:2]) .== h * mass * g .- [0, -1] * internal_force  # (5)
        mass * (vnext[3] - v[3]) == [0, -1]' * external_force + internal_force
        qnext - q .== h .* vnext # (6)
    end

    # @constraints model begin
    #     mass * (vnext - v) .== h * total_force # (5)
    #     qnext - q .== h .* vnext # (6)
    # end

    ConditionalJuMP.disjunction!(
        model,
        [@?(leg_position_in_world(qnext) ∈ P) for P in env.free_regions]) # (7)

    LCPUpdate(qnext, vnext, contacts, join_limit_results)
end

function simulate(q0, v0, controller, env::Environment, N)
    q, v = q0, v0
    results = LCPUpdate{Float64}[]
    for i in 1:N
        m = Model(solver=CbcSolver())
        u = controller(q, v)
        up = update(q, v, u, env, m)
        solve(m)
        push!(results, getvalue(up))
        q = results[end].q
        v = results[end].v
    end
    results
end

function optimize(q0, v0, env::Environment, N::Integer)::Vector{LCPUpdate{Float64}}
    q, v = q0, v0
    m = Model(solver=CbcSolver())
    results = []
    for i in 1:N
        up = update(q, v, env, m)
        push!(results, up)
        q = results[end].q
        v = results[end].v
    end
    solve(m)
    getvalue.(results)
end

function optimize(q0, v0, env::Environment, seed::Vector{<:LCPUpdate})
    q, v = q0, v0
    m = Model(solver=CbcSolver())
    results = []
    for i in 1:N
        up = update(q, v, env, m)
        setvalue(up, seed[i])
        push!(results, up)
        q = results[end].q
        v = results[end].v
    end
    warmstart!(m, true)
    @assert sum(m.colCat .== :Bin) == 0
    solve(m)
    getvalue.(results)
end


# env = Environment(
#     [
#         Obstacle(
#             SimpleHRepresentation{2, Float64}([0 1], [0]),
#             HalfSpace{2, Float64}([0, 1], 0)
#         ),
#         Obstacle(
#             SimpleHRepresentation{2, Float64}([-1 0], [-0.2]),
#             HalfSpace{2, Float64}([-1, 0], -0.2)
#         )
#     ],
#     [
#         SimpleHRepresentation{2, Float64}(
#             [0 -1;
#              1 0],
#             [0, 0.2])
#     ]
# )

# q0 = [-0.5, 0.5]
# v0 = [3, -1.5]
# N = 20
# results1 = simulate(q0, v0, env, N)
# results2 = optimize(q0, v0, env, N)
# @test all([r1.q ≈ r2.q for (r1, r2) in zip(results1, results2)])

# results_seeded = optimize(q0, v0, env, results1)
# @test all([r1.q ≈ r2.q for (r1, r2) in zip(results1, results_seeded)])

# if Pkg.installed("DrakeVisualizer") !== nothing
#     @eval using DrakeVisualizer;
#     @eval using CoordinateTransformations
#     DrakeVisualizer.any_open_windows() || DrakeVisualizer.new_window()

#     vis = Visualizer()[:block]
#     setgeometry!(vis, HyperRectangle(Vec(-0.1, -0.1, 0), Vec(0.2, 0.2, 0.2)))

#     q = [r.q for r in results1]
#     for qi in q
#         settransform!(vis, Translation(qi[1], 0, qi[2]))
#         sleep(h)
#     end
# end

end