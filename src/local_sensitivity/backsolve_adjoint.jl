struct ODEBacksolveSensitivityFunction{rateType,uType,uType2,UF,PF,G,JC,GC,DG,TJ,PJT,PJC,CP,SType,CV} <: SensitivityFunction
  uf::UF
  pf::PF
  g::G
  J::TJ
  pJ::PJT
  dg_val::uType
  jac_config::JC
  g_grad_config::GC
  paramjac_config::PJC
  sensealg::BacksolveAdjoint
  f_cache::rateType
  discrete::Bool
  y::uType2
  sol::SType
  dg::DG
  checkpoints::CP
  colorvec::CV
  isautojacvec::Bool
end

@noinline function ODEBacksolveSensitivityFunction(g,u0,p,sensealg,discrete,sol,dg,checkpoints,tspan,colorvec)
  numparams = p isa Zygote.Params ? sum(length.(p)) : length(p)
  numindvar = length(u0)
  # if there is an analytical Jacobian provided, we are not going to do automatic `jac*vec`
  f = sol.prob.f
  isautojacvec = DiffEqBase.has_jac(f) ? false : get_jacvec(sensealg)
  J = isautojacvec ? nothing : similar(u0, numindvar, numindvar)

  if !discrete
    if dg != nothing || isautojacvec
      pg = nothing
      pg_config = nothing
    else
      pg = UGradientWrapper(g,tspan[2],p)
      pg_config = build_grad_config(sensealg,pg,u0,p)
    end
  else
    pg = nothing
    pg_config = nothing
  end

  if DiffEqBase.has_jac(f) || isautojacvec
    jac_config = nothing
    uf = nothing
  else
    uf = DiffEqDiffTools.UJacobianWrapper(f,tspan[2],p)
    jac_config = build_jac_config(sensealg,uf,u0)
  end

  y = copy(sol(tspan[1])) # TODO: Has to start at interpolation value!

  if DiffEqBase.has_paramjac(f) || isautojacvec
    paramjac_config = nothing
    pf = nothing
  else
    pf = DiffEqDiffTools.ParamJacobianWrapper(f,tspan[1],y)
    paramjac_config = build_param_jac_config(sensealg,pf,y,p)
  end

  pJ = isautojacvec ? nothing : similar(sol.prob.u0, numindvar, numparams)

  dg_val = similar(u0, numindvar) # number of funcs size
  f_cache = deepcopy(u0)

  return ODEBacksolveSensitivityFunction(uf,pf,pg,J,pJ,dg_val,
                               jac_config,pg_config,paramjac_config,
                               sensealg,f_cache,
                               discrete,y,sol,dg,checkpoints,colorvec,
                               isautojacvec)
end

function vecjacobian!(dλ, λ, p, t, S, dgrad=nothing, dy=nothing)
  @unpack isautojacvec, y, sol = S
  f = sol.prob.f
  if !isautojacvec
    @unpack J, uf, f_cache, jac_config, sensealg = S
    if DiffEqBase.has_jac(f)
      f.jac(J,y,p,t) # Calculate the Jacobian into J
    else
      uf.t = t
      jacobian!(J, uf, y, f_cache, sensealg, jac_config)
    end
    mul!(dλ',λ',J)
  else
    if DiffEqBase.isinplace(sol.prob)
      _dy, back = Tracker.forward(y, sol.prob.p) do u, p
        out_ = map(zero, u)
        f(out_, u, p, t)
        Tracker.collect(out_)
      end
      dλ[:], dgrad[:] = Tracker.data.(back(λ))
      dy[:] = vec(Tracker.data(_dy))
    elseif !(sol.prob.p isa Zygote.Params)
      _dy, back = Zygote.pullback(y, sol.prob.p) do u, p
        vec(f(u, p, t))
      end
      tmp1,tmp2 = back(λ)
      dλ[:] .= tmp1
      dgrad[:] .= tmp2
      dy[:] .= vec(_dy)
    else # Not in-place and p is a Params

      # This is the hackiest hack of the west specifically to get Zygote
      # Implicit parameters to work. This should go away ASAP!

      _dy, back = Zygote.pullback(y, S.sol.prob.p) do u, p
        vec(f(u, p, t))
      end

      _idy, iback = Zygote.pullback(S.sol.prob.p) do
        vec(f(y, p, t))
      end

      igs = iback(λ)
      vs = zeros(Float32, sum(length.(S.sol.prob.p)))
      i = 1
      for p in S.sol.prob.p
        g = igs[p]
        g isa AbstractArray || continue
        vs[i:i+length(g)-1] = g
        i += length(g)
      end
      eback = back(λ)
      dλ[:] = eback[1]
      dgrad[:] = vec(vs)
      dy[:] = vec(_dy)
    end
  end
  return nothing
end

# u = λ'
function (S::ODEBacksolveSensitivityFunction)(du,u,p,t)
  @unpack y, sol, sensealg, discrete, dg, dg_val, g, g_grad_config, isautojacvec = S
  idx = length(y)
  f = sol.prob.f

  λ     = @view u[1:idx]
  dλ    = @view du[1:idx]
  grad  = @view u[idx+1:end-idx]
  dgrad = @view du[idx+1:end-idx]
  _y    = @view u[end-idx+1:end]
  dy    = @view du[end-idx+1:end]
  copyto!(vec(y), _y)
  isautojacvec || f(dy, _y, p, t)

  vecjacobian!(dλ, λ, p, t, S, dgrad, dy)

  dλ .*= -one(eltype(λ))

  if !discrete
    if dg != nothing
      dg(dg_val,y,p,t)
    else
      g.t = t
      gradient!(dg_val, g, y, sensealg, g_grad_config)
    end
    dλ .+= dg_val
  end

  if !isautojacvec
    @unpack pJ, pf, paramjac_config, f_cache = S
    if DiffEqBase.has_paramjac(f)
      f.paramjac(pJ,y,sol.prob.p,t) # Calculate the parameter Jacobian into pJ
    else
      jacobian!(pJ, pf, sol.prob.p, f_cache, sensealg, paramjac_config)
    end
    mul!(dgrad',λ',pJ)
  end
  nothing
end

# g is either g(t,u,p) or discrete g(t,u,i)
@noinline function ODEAdjointProblem(sol,sensealg::BacksolveAdjoint,
                                     g,t=nothing,dg=nothing;
                                     checkpoints=sol.t,
                                     callback=CallbackSet())
  f = sol.prob.f
  tspan = (sol.prob.tspan[2],sol.prob.tspan[1])
  discrete = t != nothing

  p = sol.prob.p
  p === DiffEqBase.NullParameters() && error("Your model does not have parameters, and thus it is impossible to calculate the derivative of the solution with respect to the parameters. Your model must have parameters to use parameter sensitivity calculations!")
  p isa Zygote.Params && sensealg.autojacvec == false && error("Use of Zygote.Params requires autojacvec=true")
  numparams = p isa Zygote.Params ? sum(length.(p)) : length(p)

  u0 = zero(sol.prob.u0)
  len = length(u0)+numparams
  λ = similar(u0, len)
  sense = ODEBacksolveSensitivityFunction(g,u0,
                                        p,sensealg,discrete,
                                        sol,dg,checkpoints,tspan,f.colorvec)

  init_cb = t !== nothing && sol.prob.tspan[2] == t[end]
  cb = generate_callbacks(sense, g, λ, t, callback, init_cb)
  z0 = [vec(zero(λ)); vec(sense.y)]
  ODEProblem(sense,z0,tspan,p,callback=cb)
end
