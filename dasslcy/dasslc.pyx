#cython: boundscheck=False
#cython: wraparound=False

# TODO Accept np.array([1, 0]) with int and convert to float inside solve function
# TODO: Profile

import numpy as np
cimport numpy as np
cimport dasslcy.dasslc_def as dasslc_def #edit 2024jul04

np.import_array()

cdef object pyres
cdef int SHARED_RES_MEM = 0

cdef dasslc_def.BOOL residuals(dasslc_def.PTR_ROOT *root,
                                dasslc_def.REAL t, dasslc_def.REAL *y,
                                dasslc_def.REAL *yp, dasslc_def.REAL *res,
                                dasslc_def.BOOL *jac) noexcept: #edit 2024jul04
    cdef:
        np.npy_intp shape[1]
        int size, j
        cdef int carr[3]
        np.float64_t[:] res_view
        np.ndarray y_np
        np.ndarray yp_np, res_shared
        tuple return_pyres

    size = root.rank
    shape[0] = <np.npy_intp>size
    y_np = np.PyArray_SimpleNewFromData(1, shape, np.NPY_DOUBLE, y)
    yp_np = np.PyArray_SimpleNewFromData(1, shape, np.NPY_DOUBLE, yp) #PyINcre???

    # Check for extra user arguments
    rpar = None if root.user is NULL else <object>root.user

    if SHARED_RES_MEM < 1:
        if rpar is None:
            arglist = (t, y_np, yp_np)
        else:
            arglist = (t, y_np, yp_np, rpar)
    else:
        # &res_view[0] = res
        res_shared = np.PyArray_SimpleNewFromData(1, shape, np.NPY_DOUBLE, res) #PyINcre???
        if rpar is None:
            arglist = (t, y_np, yp_np, res_shared)
        else:
            arglist = (t, y_np, yp_np, rpar, res_shared)

    # Run python function
    return_pyres = pyres(*arglist)

    # Copying data from python to c at &res[0]
    if SHARED_RES_MEM < 1:
        res_view = return_pyres[0]
        for j in range(size):
            res[j] = res_view[j]

    ires = <int> return_pyres[1]
    return ires

def solve(resfun, np.float64_t[:] tspan, np.float64_t[:] y0,
                    np.float64_t[:] yp0 = None, rpar=None, rtol=1e-6,
                    atol=1e-8, index=None, int share_res = 0): #, np.int_t[:] index=None
    global pyres
    global SHARED_RES_MEM

    cdef:
        dasslc_def.PTR_ROOT root
        int neq, ntp, ntp_out
        dasslc_def.REAL t0, *yp_ptr
        dasslc_def.BOOL err
        np.ndarray[np.float64_t, ndim=2] y_sol, yp_sol
        np.float64_t[:] t_sol
        int j, k
        float tf
        np.ndarray[int] index_np
        int *index_ptr
        int index_fake[5]

    pyres = resfun
    neq = y0.size
    ntp = tspan.size

    # Error when using the &index[0] directly, thus creating a helper np.array
    if index is None:
        index_ptr = NULL
    else:
        if isinstance(index, int):
            index_np = np.array([index], dtype=np.intc)
        else:
            index_np = np.empty(index.size, dtype=np.intc)
            for j in range(index.size):
                index_np[j] = index[j]
        index_ptr = <int*>&index_np[0]

    # Set the rpar if any
    if rpar is None:
        root.user = NULL
    else:
        root.user = <void*>rpar

    if yp0 is None:
        yp_ptr = NULL
    else:
        yp_ptr = &yp0[0]

    SHARED_RES_MEM = share_res

    # Setup dasslc:
    t0 = tspan[0] if ntp > 1 else 0.0
    err = dasslc_def.daSetup("?",&root, residuals, neq,
                                t0, &y0[0], yp_ptr, index_ptr, NULL, NULL)
    if err > 0:
        print('Setup error here')

    # Configure root structure
    root.iter.stol = 1
    root.iter.atol[0] = atol
    root.iter.rtol[0] = rtol

    # Define delta t and final time based on tspan input
    ntp_out = ntp if ntp > 2 else 100
    if ntp == 1:
        dt = <double> tspan[0]/(ntp_out-1)
        tf = t0 + dt
    elif ntp == 2:
        dt = <double> (tspan[1]-tspan[0])/(ntp_out-1)
        tf = t0 + dt
    else:
        tf = tspan[1]

    # Find initial derivatives if not given
    if yp0 is None:
        err = dasslc_def.dasslc(dasslc_def.INITIAL_COND, &root,
                                residuals, &t0, tf, NULL, NULL)
        if (err < 0):
            error = "Failed in finding consistent initial condition. Error: {}".format(err)
            dasslc_def.daFree(&root)
            raise TypeError(error)

    # Create and Update solution at t0
    y_sol = np.empty([ntp_out, neq])
    yp_sol = np.empty([ntp_out, neq])
    t_sol = np.empty(ntp_out)
    for j in range(neq):
        y_sol[0, j] = root.y[j]
        yp_sol[0, j] = root.yp[j]

    # Call the dasslc function for all tspan
    for k in range(1, ntp_out):
        tf = tspan[k] if ntp > 2 else t0 + dt
        err = dasslc_def.dasslc(dasslc_def.TRANSIENT, &root, residuals, &t0, tf, NULL, NULL)
        if (err < 0):
            error = "Error during integration: {}".format(err)
            dasslc_def.daFree(&root)
            raise TypeError(error)
        t_sol[k] = root.t
        for j in range(neq):
            y_sol[k, j] = root.y[j]
            yp_sol[k, j] = root.yp[j]

    # Clean Up
    dasslc_def.daFree(&root)

    return (t_sol, y_sol, yp_sol)
