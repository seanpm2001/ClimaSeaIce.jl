using Oceananigans.Grids: AbstractGrid, architecture
using Oceananigans.TimeSteppers: store_field_tendencies!
using ClimaSeaIce.SeaIceDynamics: AbstractRheology
using Printf

"""
    step_momentum!(model, rheology::AbstractExplicitRheology, Δt, χ)

function for stepping u and v in the case of _explicit_ solvers.
The sea-ice momentum equations are characterized by smaller time-scale than 
sea-ice thermodynamics and sea-ice tracer advection, therefore explicit rheologies require 
substepping over a set number of substeps.
"""
function step_momentum!(model, solver::ExplicitMomentumSolver, Δt, args...)

    grid = model.grid
    arch = architecture(grid)
    rheology = solver.rheology
    initialize_substepping!(model, solver)

    # The atmospheric stress component is fixed during time-stepping
    τua = model.external_momentum_stresses.u
    τva = model.external_momentum_stresses.v

    # Either a C-grid or an E-grid
    dgrid = dynamics_grid(solver)

    _u_velocity_step! = dgrid isa CGridDynamics ? _u_cgrid_velocity_step! : _u_egrid_velocity_step!
    _v_velocity_step! = dgrid isa CGridDynamics ? _v_cgrid_velocity_step! : _v_egrid_velocity_step!

    # We step the momentum equation using a leap-frog scheme
    # where we alternate the order of solving u and v 
    for substep in 1:solver.substeps
        
        # Fill halos of the updated velocities
        fill_velocities_halo_regions!(model, solver, model.clock, fields(model))
    
        # Compute stresses! depending on the particular rheology implementation
        compute_stresses!(model, solver, rheology, Δt)

        # Fill halos of the updated stresses
        fill_stresses_halo_regions!(solver.auxiliary_fields, dgrid, rheology, model.clock, fields(model))

        args = (model.velocities, grid, Δt, 
                model.clock,
                model.ocean_velocities,
                model.coriolis,
                rheology,
                solver.auxiliary_fields,
                solver.substeps,
                solver.substepping_coefficient,
                model.ice_thickness,
                model.ice_concentration,
                model.ice_density,
                solver.ocean_ice_drag_coefficient)

        # The momentum equations are solved using an alternating leap-frog algorithm
        # for u and v (used for the ocean - ice stresses and the coriolis term)
        # In even substeps we calculate uⁿ⁺¹ = f(vⁿ) and vⁿ⁺¹ = f(uⁿ⁺¹).
        # In odd substeps we switch and calculate vⁿ⁺¹ = f(uⁿ) and uⁿ⁺¹ = f(vⁿ⁺¹).
        if iseven(substep)
            launch!(arch, grid, :xy, _u_velocity_step!, args..., τua, nothing, fields(model))
            launch!(arch, grid, :xy, _v_velocity_step!, args..., τva, nothing, fields(model))
        else
            launch!(arch, grid, :xy, _v_velocity_step!, args..., τva, nothing, fields(model))
            launch!(arch, grid, :xy, _u_velocity_step!, args..., τua, nothing, fields(model))
        end
    end

    return nothing
end
