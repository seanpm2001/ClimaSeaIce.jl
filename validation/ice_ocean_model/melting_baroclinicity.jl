using Oceananigans
using Oceananigans.Architectures: arch_array
using Oceananigans.Fields: ZeroField, ConstantField
using Oceananigans.TurbulenceClosures: CATKEVerticalDiffusivity
using Oceananigans.Units
using Oceananigans.Utils: prettysummary

using SeawaterPolynomials: TEOS10EquationOfState, thermal_expansion, haline_contraction

using ClimaSeaIce
using ClimaSeaIce.SeaIceThermodynamics: melting_temperature
using ClimaSeaIce.SeaIceThermodynamics.HeatBoundaryConditions: RadiativeEmission, IceWaterThermalEquilibrium

using Printf
using GLMakie
using Statistics

include("ice_ocean_model.jl")

arch = CPU()
Nx = Ny = 256
Nz = 10
Lz = 400
longitude = (-10, 10)
latitude = (-70, -60)
halo = (6, 6, 6)
topology = (Periodic, Bounded, Bounded)

ice_grid = LatitudeLongitudeGrid(arch; longitude, latitude,
                           size = (Nx, Ny),
                           topology = (topology[1], topology[2], Flat),
                           halo = halo[1:2])

ocean_grid = LatitudeLongitudeGrid(arch; topology, halo, longitude, latitude,
                             size = (Nx, Ny, Nz),
                             z = (-Lz, 0))

# Top boundary conditions:
#   - outgoing radiative fluxes emitted from surface
#   - incoming shortwave radiation starting after 40 days
ocean = ocean_simulation(ocean_grid)
ocean.Δt = 20minutes

Nz = size(ocean_grid, 3)
u, v, w = ocean.model.velocities
ocean_velocities = (u = interior(u, :, :, Nz),
                    v = interior(v, :, :, Nz))

bottom_bc = IceWaterThermalEquilibrium(ConstantField(30)) #ocean_surface_salinity)

ice_thermodynamics = SlabSeaIceThermodynamics(ice_grid;
                                              top_heat_boundary_condition = PrescribedTemperature(0),
                                              bottom_heat_boundary_condition = bottom_bc,
                                              ice_consolidation_thickness = 0.05,
                                              internal_heat_flux = ConductiveFlux(conductivity=2))

ice_model = SeaIceModel(ice_grid;
                        velocities = ocean_velocities,
                        advection  = WENO(),
                        ice_thermodynamics,
                        ice_salinity = 4,
                        top_heat_flux = ConstantField(0), # W m⁻²
                        bottom_heat_flux = IceWaterThermalEquilibrium(ConstantField(30)))

sea_ice = Simulation(ice_model, Δt=20minutes, verbose=false)

# Initial condition
S₀ = 30
T₀ = melting_temperature(ice_model.phase_transitions.liquidus, S₀) + 2.0

N²S = 1e-6
g = ocean_model.buoyancy.model.gravitational_acceleration
dSdz = - g * β * N²S

uᵢ(x, y, z) = 0.0
Tᵢ(x, y, z) = 0.0
Sᵢ(x, y, z) = 4.0 + dSdz * z #+ 0.1 * randn()

function hᵢ(x, y)
    if sqrt(x^2 + y^2) < 20kilometers
        #return 1 + 0.1 * rand()
        return 2
    else 
        return 0
    end
end

set!(ocean.model, u=uᵢ, S=4, T=0.0)
set!(sea_ice.model, h=hᵢ)

coupled_model = OceanSeaIceModel(ocean, sea_ice; radiation = nothing, atmosphere = nothing)
coupled_simulation = Simulation(coupled_model, Δt=20minutes, stop_time=20days)

S = ocean_model.tracers.S
by = - g * β * ∂y(S)

function progress(sim)
    h = sim.model.ice.model.ice_thickness
    S = sim.model.ocean.model.tracers.S
    T = sim.model.ocean.model.tracers.T
    u = sim.model.ocean.model.velocities.u
    msg1 = @sprintf("Iter: % 6d, time: % 12s", iteration(sim), prettytime(sim))
    msg2 = @sprintf(", max(h): %.2f", maximum(h))
    msg3 = @sprintf(", min(S): %.2f", minimum(S))
    msg4 = @sprintf(", extrema(T): (%.2f, %.2f)", minimum(T), maximum(T))
    msg5 = @sprintf(", max|∂y b|: %.2e", maximum(abs, by))
    msg6 = @sprintf(", max|u|: %.2e", maximum(abs, u))
    @info msg1 * msg2 * msg3 * msg4 * msg5 * msg6
    return nothing
end

coupled_simulation.callbacks[:progress] = Callback(progress, IterationInterval(10))

h = ice_model.ice_thickness
T = ocean_model.tracers.T
S = ocean_model.tracers.S
u, v, w = ocean_model.velocities
η = ocean_model.free_surface.η

ht = []
Tt = []
Ft = []
Qt = []
St = []
ut = []
vt = []
ηt = []
ζt = []
tt = []

ζ = Field(∂x(v) - ∂y(u))

function saveoutput(sim)
    compute!(ζ)
    hn = Array(interior(h, :, :, 1))
    Fn = Array(interior(Qˢ, :, :, 1))
    Qn = Array(interior(Qᵀ, :, :, 1))
    Tn = Array(interior(T, :, :, Nz))
    Sn = Array(interior(S, :, :, Nz))
    un = Array(interior(u, :, :, Nz))
    vn = Array(interior(v, :, :, Nz))
    ηn = Array(interior(η, :, :, 1))
    ζn = Array(interior(ζ, :, :, Nz))
    push!(ht, hn)
    push!(Ft, Fn)
    push!(Qt, Qn)
    push!(Tt, Tn)
    push!(St, Sn)
    push!(ut, un)
    push!(vt, vn)
    push!(ηt, ηn)
    push!(ζt, ζn)
    push!(tt, time(sim))
end

coupled_simulation.callbacks[:output] = Callback(saveoutput, IterationInterval(10))

run!(coupled_simulation)

#####
##### Viz
#####

set_theme!(Theme(fontsize=24))

x = xnodes(ocean_grid, Center())
y = ynodes(ocean_grid, Center())

fig = Figure(size=(2400, 700))

axh = Axis(fig[1, 1], xlabel="x (km)", ylabel="y (km)", title="Ice thickness")
axT = Axis(fig[1, 2], xlabel="x (km)", ylabel="y (km)", title="Ocean surface temperature")
axS = Axis(fig[1, 3], xlabel="x (km)", ylabel="y (km)", title="Ocean surface salinity")
axZ = Axis(fig[1, 4], xlabel="x (km)", ylabel="y (km)", title="Ocean vorticity")

Nt = length(tt)
slider = Slider(fig[2, 1:4], range=1:Nt, startvalue=Nt)
n = slider.value

title = @lift string("Melt-driven baroclinic instability after ", prettytime(tt[$n]))
Label(fig[0, 1:3], title)

hn = @lift ht[$n]
Fn = @lift Ft[$n]
Tn = @lift Tt[$n]
Sn = @lift St[$n]
un = @lift ut[$n]
vn = @lift vt[$n]
ηn = @lift ηt[$n]
ζn = @lift ζt[$n]
Un = @lift mean(ut[$n], dims=1)[:]

x = x ./ 1e3
y = y ./ 1e3

Stop = view(S, :, :, Nz)
Smax = maximum(Stop)
Smin = minimum(Stop)

compute!(ζ)
ζtop = view(ζ, :, :, Nz)
ζmax = maximum(abs, ζtop)
ζlim = 2e-4 #ζmax / 2

heatmap!(axh, x, y, hn, colorrange=(0, 1), colormap=:grays)
heatmap!(axT, x, y, Tn, colormap=:heat)
heatmap!(axS, x, y, Sn, colorrange = (29, 30), colormap=:haline)
heatmap!(axZ, x, y, ζn, colorrange=(-ζlim, ζlim), colormap=:redblue)

#heatmap!(axZ, x, y, Tn, colormap=:heat)
#heatmap!(axF, x, y, Fn)

display(fig)

#=
record(fig, "salty_baroclinic_ice_cube.mp4", 1:Nt, framerate=48) do nn
    @info string(nn)
    n[] = nn
end
=#

