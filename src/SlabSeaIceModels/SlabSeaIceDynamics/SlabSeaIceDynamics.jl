module SlabSeaIceDynamics

using ClimaSeaIce
using ClimaSeaIce.SlabSeaIceModels

using Oceananigans
using KernelAbstractions: @kernel, @index
using Oceananigans.Utils: launch!
using Oceananigans.Operators
using Oceananigans.Grids
using Oceananigans.Grids: architecture

import ClimaSeaIce.SlabSeaIceModels: step_momentum!

## A Framework to solve for the ice momentum equation, in the form:
## 
##     ∂u                   τₒ    τₐ
##     -- + f x u = ∇ ⋅ σ + --  + -- + g∇η
##     ∂t                   mᵢ    mᵢ
## 
## where the terms (left to right) represent the 
## - time derivative of the ice velocity
## - coriolis force
## - divergence of internal stresses
## - ice-ocean boundary stress (calculated in step_momentum!)
## - ice-atmosphere boundary stress (provided as an external flux)
## - ocean dynamic surface

"""
    AbstractRheology

Abstract supertype for rheologies that inform the treatment of the stress divergence ∇⋅σ.
"""
abstract type AbstractRheology end

include("nothing_dynamics.jl")
include("momentum_stepping_kernels.jl")
include("explicit_dynamics.jl")
include("free_drift_rheology.jl")

end