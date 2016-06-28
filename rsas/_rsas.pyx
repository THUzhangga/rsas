# cython: profile=True
# -*- coding: utf-8 -*-
"""
.. module:: rsas
   :platform: Unix, Windows
   :synopsis: Time-variable transport using storage selection (SAS) functions

.. moduleauthor:: Ciaran J. Harman
"""

from __future__ import division
import cython
import numpy as np
cimport numpy as np
from warnings import warn
dtype = np.float64
ctypedef np.float64_t dtype_t
ctypedef np.int_t inttype_t
ctypedef np.long_t longtype_t
cdef inline np.float64_t float64_max(np.float64_t a, np.float64_t b): return a if a >= b else b
cdef inline np.float64_t float64_min(np.float64_t a, np.float64_t b): return a if a <= b else b
from _rsas_functions import rSASFunctionClass
from scipy.special import gamma as gamma_function
from scipy.special import gammainc
from scipy.special import erfc
from scipy.interpolate import interp1d
from scipy.optimize import fmin, minimize_scalar, fsolve
import time
#import rsas._util

# for debugging
DEBUG = False
VERBOSE = False
def _debug(statement):
    """Prints debuging messages if DEBUG==True

    """
    if DEBUG:
        print statement,

def _verbose(statement):
    """Prints debuging messages if VERBOSE==True

    """
    if VERBOSE:
        print statement

def solve(J, Q, rSAS_fun, mode='RK4', ST_init = None, dt = 1, n_substeps = 1,
          full_outputs=True, CS_init = None, C_J=None, alpha=None, k1=None, C_eq=None,  C_old=None, verbose=False, debug=False):
    """Solve the rSAS model for given fluxes

    Args:
        J : n x 1 float64 ndarray
            Timestep-averaged inflow timeseries for n timesteps
        Q : n x q float64 ndarray or list of length n 1D float64 ndarray
            Timestep-averaged outflow timeseries for n timesteps and q outflow fluxes.
            Must have same units and length as J.  For multiple outflows, each column
            represents one outflow
        rSAS_fun : rSASFunctionClass or list of rSASFunctionClass generated by rsas.create_function
            The number of rSASFunctionClass in this list must be the same as the
            number of columns in Q if Q is an ndarray, or elements in Q if it is a list.

    Kwargs:
        ST_init : m+1 x 1 float64 ndarray
            Initial condition for the age-ranked storage. The length of ST_init
            determines the maximum age calculated. The first entry must be 0
            (corresponding to zero age). To calculate transit time dsitributions up
            to m timesteps in age, ST_init should have length m + 1. The default
            initial condition is ST_init=np.zeros(len(J) + 1).
        dt : float (default 1)
            Timestep, assuming same units as J
        n_substeps : int (default 1)
            If n_substeps>1, the timesteps are subdivided to allow a more accurate
            solution.
        full_outputs : bool (default True)
            Option to return the full state variables array ST the cumulative
            transit time distributions PQ, and other variables
        verbose : bool (default False)
            Print information about the progression of the model
        debug : bool (default False)
            Print information ever substep
        C_J : n x s float64 ndarray (default None)
            Optional timeseries of inflow concentrations for s solutes
        CS_init : s X 1 or m+1 x s float64 ndarray
            Initial condition for calculating the age-ranked solute mass. Must be a 2-D
            array the same length as ST_init or a 1-D array, where the concentration in
            storage is assumed to be constant for all ages.
        C_old : s x 1 float64 ndarray (default None)
            Optional concentration of the 'unobserved fraction' of Q (from inflows
            prior to the start of the simulation) for correcting C_Q. If ST_init is
            not given or set to all zeros, the unobserved fraction will be assumed 
            for water that entered prior to time zero (diagonal of the PQ matrix).
            Otherwise it will be used for water older than the oldest water in ST 
            (the bottom row of the PQ matrix).
        alpha : n x q x s or q x s float64 ndarray
            Optional partitioning coefficient relating discharge concentrations cQ and storage
            concentration cS as cQ = alpha x cS. Alpha can be specified as a 2D q x s array if
            it is assumed to be constant, or as a n x q x s array if it is to vary in time.
        k1 : s x 1 or n x s float64 ndarray (default none)
            Optional first order reaction rate. May be specified as n x s if allowed to vary in time, or s x 1 if constant.
        C_eq : s x 1 or n x s float64 ndarray (default none)
            Optional equilibrium concentration for first-order reaction rate. Assumed to be 0 if omitted.

    Returns:
        A dict with the following keys:
            'ST' : m+1 x n+1 numpy float64 2D array
                Array of age-ranked storage for n times, m ages. (full_outputs=True only)
            'PQ' : m+1 x n+1 x q numpy float64 2D array
                List of time-varying cumulative transit time distributions for n times,
                m ages, and q fluxes. (full_outputs=True only)
            'WaterBalance' : m x n numpy float64 2D array
                Should always be within tolerances of zero, unless something is very
                wrong. (full_outputs=True only)
            'C_Q' : n x q x s float64 ndarray
                If C_J is supplied, C_Q is the timeseries of outflow concentration
            'MS' : m+1 x n+1 x s float64 ndarray
                Array of age-ranked solute mass for n times, m ages, and s solutes.
                (full_outputs=True only)
            'MQ' : m+1 x n+1 x q x s float64 ndarray
                Array of age-ranked solute mass flux for n times, m ages, q fluxes and s
                solutes. (full_outputs=True only)
            'MR' : m+1 x n+1 x s float64 ndarray
                Array of age-ranked solute reaction flux for n times, m ages, and s
                solutes. (full_outputs=True only)
            'SoluteBalance' : m x n x s float64 ndarray
                Should always be within tolerances of zero, unless something is very
                wrong. (full_outputs=True only)

    For each of the arrays in the full outputs each row represents an age, and each
    column is a timestep. For n timesteps and m ages, ST will have dimensions
    (n+1) x (m+1), with the first row representing age T = 0 and the first
    column derived from the initial condition.
    """
    # This function just does input checking
    # then calls the private implementation functions defined below
    global VERBOSE
    global DEBUG
    VERBOSE=verbose
    DEBUG=debug
    if type(J) is not np.ndarray:
        J = np.array(J)
    if J.ndim!=1:
        raise TypeError('J must be a 1-D array')
    J = J.astype(np.float)
    if type(Q) is not np.ndarray:
        Q = np.array(Q).T
    Q = Q.astype(np.float)
    if (Q.ndim>2) or (Q.shape[0]!=len(J)):
        raise TypeError('Q must be a 1 or 2-D numpy array with a column for each outflow\nor a list of 1-D numpy arrays (like ''[Q1, Q2]'')\nand each must be the same size as J')
    elif Q.ndim==1:
            Q=np.c_[Q]
    if ST_init is not None:
        if type(ST_init) is not np.ndarray:
            ST_init = np.array(ST_init)
        if ST_init.ndim!=1:
            raise TypeError('ST_init must be a 1-D array')
        if ST_init[0]!=0:
            raise TypeError('ST_init[0] must be 0')
    if not type(rSAS_fun) is list:
        rSAS_fun = [rSAS_fun]
    if Q.shape[1]!=len(rSAS_fun):
        raise TypeError('Each rSAS function must have a corresponding outflow in Q. Numbers don''t match')
    for fun in rSAS_fun:
        fun_methods = [method for method in dir(fun) if callable(getattr(fun, method))]
        if not ('cdf_all' in fun_methods and 'cdf_i' in fun_methods):
            raise TypeError('Each rSAS function must have methods rSAS_fun.cdf_all and rSAS_fun.cdf_i')
    if type(full_outputs) is not bool:
        raise TypeError('full_outputs must be a boolean (True/False)')
    if C_J is not None:
        if type(C_J) is not np.ndarray:
            C_J = np.array(C_J, dtype=dtype)
        if ((C_J.ndim>2) or (C_J.shape[0]!=len(J))):
            raise TypeError('C_J must be a 1 or 2-D array with a first dimension the same length as J')
        elif C_J.ndim==1:
                C_J=np.c_[C_J]
        C_J=C_J.astype(np.float)
        if alpha is not None:
            if type(alpha) is not np.ndarray:
                alpha = np.array(alpha, dtype=dtype)
            if alpha.ndim==2:
                alpha = np.tile(alpha,(len(J),1,1))
            if (alpha.shape[2]!=C_J.shape[1]) and (alpha.shape[1]!=Q.shape[1]):
                raise TypeError("alpha array dimensions don't match other inputs")
            alpha = alpha.astype(dtype)
        else:
            alpha = np.ones((len(J), Q.shape[1], C_J.shape[1]))
        if k1 is not None:
            if type(k1) is not np.ndarray:
                k1 = np.array(k1, dtype=dtype)
            if k1.ndim==1:
                k1 = np.tile(k1,(len(J),1))
            if (k1.shape[1]!=C_J.shape[1]) and (k1.shape[0]!=J.shape[0]):
                raise TypeError("k1 array dimensions don't match other inputs")
            k1 = k1.astype(dtype)
        else:
            k1 = np.zeros((len(J), C_J.shape[1]))
        if C_eq is not None:
            if type(C_eq) is not np.ndarray:
                C_eq = np.array(C_eq, dtype=dtype)
            if C_eq.ndim==1:
                C_eq = np.tile(C_eq,(len(J),1))
            if (C_eq.shape[1]!=C_J.shape[1]) and (C_eq.shape[0]!=J.shape[0]):
                raise TypeError("C_eq array dimensions don't match other inputs")
            C_eq = C_eq.astype(dtype)
        else:
            C_eq = np.zeros((len(J), C_J.shape[1]))
        if C_old is not None:
            if type(C_old) is not np.ndarray:
                C_old = np.array(C_old, dtype=dtype)
            if len(C_old)!=C_J.shape[1]:
                raise TypeError('C_old must have the same number of entries as C_J has columns')
            C_old = C_old.astype(dtype)
        if CS_init is not None:
            if type(CS_init) is not np.ndarray:
                CS_init = np.array(CS_init, dtype=dtype)
            if CS_init.ndim==1:
                CS_init = np.tile(CS_init,(len(ST_init),1))
            if (CS_init.shape[1]!=C_J.shape[1]) and (CS_init.shape[0]!=ST_init.shape[0]):
                raise TypeError("CS_init array dimensions don't match other inputs")
            CS_init = CS_init.astype(dtype)
    if dt is not None:
        dt = np.float64(dt)
    if n_substeps is not None:
        n_substeps = np.int(n_substeps)
    if full_outputs==False and C_J is None:
        warn('No output will be generated! Are you sure you mean to do this?')
    # Run implemented solvers
    _verbose('Running rsas...')
    if mode=='age':
        warn('mode age is deprecated, switching to RK4')
        mode='RK4'
    if mode=='time':
        warn('mode time is deprecated, switching to RK4')
        mode='RK4'
    if mode=='RK4':
        result = _solve_RK4(J, Q, rSAS_fun, ST_init=ST_init,
                            dt=dt, n_substeps=n_substeps,
                            full_outputs=full_outputs,
                            CS_init=CS_init, C_J=C_J, alpha=alpha, k1=k1, C_eq=C_eq, C_old=C_old)
    else:
        raise TypeError('Incorrect solution mode.')
    return result


@cython.boundscheck(False)
@cython.wraparound(False)
def _solve_RK4(np.ndarray[dtype_t, ndim=1] J,
        np.ndarray[dtype_t, ndim=2] Q,
        rSAS_fun,
        np.ndarray[dtype_t, ndim=1] ST_init = None,
        dtype_t dt = 1,
        int n_substeps = 1,
        full_outputs = True,
        np.ndarray[dtype_t, ndim=2] CS_init = None,
        np.ndarray[dtype_t, ndim=2] C_J = None,
        np.ndarray[dtype_t, ndim=3] alpha = None,
        np.ndarray[dtype_t, ndim=2] k1 = None,
        np.ndarray[dtype_t, ndim=2] C_eq = None,
        np.ndarray[dtype_t, ndim=1] C_old = None):
    """rSAS model, Runge-Kutta method

    See the docstring for rsas.solve for more information
    """
    # Initialization
    # Define some variables
    cdef int k, i, j, n, timeseries_length, num_inputs, max_age
    cdef int numflux
    cdef np.float64_t start_time, h
    cdef np.ndarray[dtype_t, ndim=1] STp, STn, STt, sTt, sTn
    cdef np.ndarray[dtype_t, ndim=2] mSp, mSn, mSt
    cdef np.ndarray[dtype_t, ndim=2] PQ1, PQ2, PQ3, PQ4, PQn, pQn, pQt
    cdef np.ndarray[dtype_t, ndim=2] ST, WaterBalance
    cdef np.ndarray[dtype_t, ndim=3] MS, SoluteBalance
    cdef np.ndarray[dtype_t, ndim=3] mQ1, mQ2, mQ3, mQ4, mQn
    cdef np.ndarray[dtype_t, ndim=2] mR1, mR2, mR3, mR4, mRn
    cdef np.ndarray[dtype_t, ndim=3] PQ
    cdef np.ndarray[dtype_t, ndim=4] MQ
    cdef np.ndarray[dtype_t, ndim=3] MR
    cdef np.ndarray[dtype_t, ndim=3] C_Q
    #
    # This is useful for debugging purposes
    # dt = 1.
    # n_substeps = 1
    # full_outputs = True
    # rSAS_fun=[rSAS_fun_Q1]
    # _debug=lambda x:''
    # _verbose=lambda x:''
    # ST_init=None
    # CS_init=None
    #
    # Some lengths
    numflux = Q.shape[1]
    timeseries_length = len(J)
    max_age = len(ST_init) - 1
    M = max_age * n_substeps
    h = dt / n_substeps
    _verbose('...initializing arrays...')
    if C_J is not None:
        numsol = C_J.shape[1]
    else:
        numsol = 0
    # Create arrays to hold intermediate solutions
    STn = np.zeros(M+1, dtype=np.float64)
    STp = np.zeros(M+1, dtype=np.float64)
    STt = np.zeros(M+1, dtype=np.float64)
    PQ1 = np.zeros((M+1, numflux), dtype=np.float64)
    PQ2 = np.zeros((M+1, numflux), dtype=np.float64)
    PQ3 = np.zeros((M+1, numflux), dtype=np.float64)
    PQ4 = np.zeros((M+1, numflux), dtype=np.float64)
    PQn = np.zeros((M+1, numflux), dtype=np.float64)
    sTt = np.zeros((M), dtype=np.float64)
    sTn = np.zeros((M), dtype=np.float64)
    pQt = np.zeros((M, numflux), dtype=np.float64)
    pQn = np.zeros((M, numflux), dtype=np.float64)
    if numsol>0:
        mQ1 = np.zeros((M, numflux, numsol), dtype=np.float64)
        mQ2 = np.zeros((M, numflux, numsol), dtype=np.float64)
        mQ3 = np.zeros((M, numflux, numsol), dtype=np.float64)
        mQ4 = np.zeros((M, numflux, numsol), dtype=np.float64)
        mR1 = np.zeros((M, numsol), dtype=np.float64)
        mR2 = np.zeros((M, numsol), dtype=np.float64)
        mR3 = np.zeros((M, numsol), dtype=np.float64)
        mR4 = np.zeros((M, numsol), dtype=np.float64)
        mQn = np.zeros((M, numflux, numsol), dtype=np.float64)
        mRn = np.zeros((M, numsol), dtype=np.float64)
        mSp = np.zeros((M, numsol), dtype=np.float64)
        mSn = np.zeros((M, numsol), dtype=np.float64)
        mSt = np.zeros((M, numsol), dtype=np.float64)
        C_Q = np.zeros((timeseries_length, numflux, numsol), dtype=np.float64)
    # Create arrays to hold the state variables if they are to be outputted
    if full_outputs:
        ST = np.zeros((max_age + 1, timeseries_length + 1), dtype=np.float64)
        WaterBalance = np.zeros((max_age, timeseries_length), dtype=np.float64)
        PQ = np.zeros((max_age + 1, timeseries_length + 1, numflux), dtype=np.float64)
        if numsol>0:
            MS = np.zeros((max_age + 1, timeseries_length + 1, numsol), dtype=np.float64)
            MQ = np.zeros((max_age + 1, timeseries_length + 1, numflux, numsol), dtype=np.float64)
            MR = np.zeros((max_age + 1, timeseries_length + 1, numsol), dtype=np.float64)
            SoluteBalance = np.zeros((max_age, timeseries_length, numsol), dtype=np.float64)
        else:
            MS, MR, MQ, SoluteBalance = np.zeros((0,0,0)), np.zeros((0,0,0)), np.zeros((0,0,0,0)), np.zeros((0,0,0))
    else:
        MS, MR, MQ, SoluteBalance = np.zeros((0,0,0)), np.zeros((0,0,0)), np.zeros((0,0,0,0)), np.zeros((0,0,0))
        ST, PQ, WaterBalance = np.zeros((0,0)), np.zeros((0,0)), np.zeros((0,0))
    _verbose('...setting initial conditions...')
    # Now we solve the governing equation
    # Set up initial and boundary conditions
    if ST_init is not None:
        STn[1:] = np.cumsum(np.diff(ST_init).repeat(n_substeps, axis=0))/n_substeps
        PQn[:] = np.c_[[rSAS_fun[q].cdf_i(STn, 0) for q in range(numflux)]].T
    sTn[:] = np.diff(STn)
    if CS_init is not None:
        for s in range(numsol):
            mSn[:,s] = np.diff(CS_init[:,s] * ST_init, axis=0).repeat(n_substeps, axis=0)/n_substeps
    if full_outputs:
        ST[:,0] = STn[0:M+1:n_substeps]
        PQ[:,0,:] = PQn[0:M+1:n_substeps, :]
        if numsol>0:
            MS[:,0,:] = np.r_[np.zeros((1, numsol)), np.cumsum(mSn, axis=0)][0:M+1:n_substeps]
    start_time = time.clock()
    _verbose('...solving conservation law...')
    # Primary solution loop over time t
    for i in range(timeseries_length):
    # Loop over substeps
        for k in range(n_substeps):
            _debug('(i,k) = {},{}, '.format(i,k))
            STn, STp = STp, STn
            sTt = np.roll(sTn,1)
            sTt[0] = h * J[i]
            if numsol>0:
                mSp[1:M,:] = mSn[0:M-1,:]
                mSp[0,:] = 0.
            _debug('K1, ')
            for q in range(numflux):
                PQ1[:,q] = rSAS_fun[q].cdf_i(STp, i)
            pQt[1:M,:] = np.diff(PQ1[0:M,:], axis=0)
            pQt[0,:] = PQ1[0,:]
            for q in range(numflux):
                for s in range(numsol):
                    mQ1[:,q,s] = np.where(sTt>0, mSp[:,s] * alpha[i,q,s] * Q[i,q] * pQt[:,q] / sTt, 0.)
            STt[:] = np.maximum(0., STp + (J[i] - np.dot(Q[i,:], PQ1.T)) * h/2)
            for s in range(numsol):
                mR1[:,s] = k1[i,s] * (C_eq[i,s] * sTt - mSp[:,s])
                mSt[:,s] = mSp[:,s] - np.sum(mQ1[:,:,s], axis=1) * h/2 + mR1[:,s] * h/2
                mSt[0,s] += J[i] * C_J[i,s] * h/2
            _debug('K2, ')
            for q in range(numflux):
                PQ2[:,q] = rSAS_fun[q].cdf_i(STt, i)
            sTt[1:] = np.diff(STt[0:M], axis=0)
            sTt[0] = STt[0]
            pQt[1:,:] = np.diff(PQ2[0:M,:], axis=0)
            pQt[0,:] = PQ2[0,:]
            for q in range(numflux):
                for s in range(numsol):
                    mQ2[:,q,s] = np.where(sTt>0, mSt[:,s] * alpha[i,q,s] * Q[i,q] * pQt[:,q] / sTt, 0.)
            STt[:] = np.maximum(0., STp + (J[i] - np.dot(Q[i,:], PQ2.T)) * h/2)
            for s in range(numsol):
                mR2[:,s] = k1[i,s] * (C_eq[i,s] * sTt - mSt[:,s])
                mSt[:,s] = mSp[:,s] - np.sum(mQ2[:,:,s], axis=1) * h/2 + mR2[:,s] * h/2
                mSt[0,s] += J[i] * C_J[i,s] * h/2
            _debug('K3, ')
            for q in range(numflux):
                PQ3[:,q] = rSAS_fun[q].cdf_i(STt, i)
            sTt[1:] = np.diff(STt[0:M], axis=0)
            sTt[0] = STt[0]
            pQt[1:,:] = np.diff(PQ3[0:M,:], axis=0)
            pQt[0,:] = PQ2[0,:]
            for q in range(numflux):
                for s in range(numsol):
                    mQ3[:,q,s] = np.where(sTt>0, mSt[:,s] * alpha[i,q,s] * Q[i,q] * pQt[:,q] / sTt, 0.)
            STt[:] = np.maximum(0., STp + (J[i] - np.dot(Q[i,:], PQ3.T)) * h/2)
            for s in range(numsol):
                mR3[:,s] = k1[i,s] * (C_eq[i,s] * sTt - mSt[:,s])
                mSt[:,s] = mSp[:,s] - np.sum(mQ3[:,:,s], axis=1) * h/2 + mR3[:,s] * h/2
                mSt[0,s] += J[i] * C_J[i,s] * h
            _debug('K4, ')
            for q in range(numflux):
                PQ4[:,q] = rSAS_fun[q].cdf_i(STt, i)
            sTt[1:] = np.diff(STt[0:M], axis=0)
            sTt[0] = STt[0]
            pQt[1:,:] = np.diff(PQ4[0:M,:], axis=0)
            pQt[0,:] = PQ2[0,:]
            for q in range(numflux):
                for s in range(numsol):
                    mQ4[:,q,s] = np.where(sTt>0, mSt[:,s] * alpha[i,q,s] * Q[i,q] * pQt[:,q] / sTt, 0.)
            for s in range(numsol):
                mR4[:,s] = k1[i,s] * (C_eq[i,s] * sTt - mSt[:,s])
            _debug('Finalizing\n')
            PQn[1:M+1,:] = (PQ1 + 2*PQ2 + 2*PQ3 + PQ4)[:M,:] / 6.
            for q in range(numflux):
                if Q[i,q]==0:
                    PQn[:,q] = 0.
            STn[1:M+1] = STp[0:M] + h * (J[i] - np.dot(Q[i,:], PQn[1:M+1,:].T))
            sTn = np.diff(STn, axis=0)
            pQn = np.diff(PQn, axis=0)
            if numsol>0:
                mQn = (mQ1 + 2*mQ2 + 2*mQ3 + mQ4) / 6.
                mRn = (mR1 + 2*mR2 + 2*mR3 + mR4) / 6.
            for s in range(numsol):
                mSn[:,s] = mSp[:,s] + mRn[:,s] * h
                mSn[0,s]+= J[i] * C_J[i,s] * h
                for q in range(numflux):
                    mSn[:,s] += - mQn[:,q,s] * h
                    if Q[i,q]>0:
                        C_Q[i,q,s] += np.sum(mQn[:,q,s]) / Q[i,q] / n_substeps
            if full_outputs:
                for q in range(numflux):
                    PQ[1, i+1, q] += np.sum(pQn[:k+1, q])/n_substeps
                    PQ[2:max_age+1, i+1, q] += np.sum(np.reshape(pQn[k+1:M-(n_substeps-k-1), q],(max_age-1,n_substeps)), axis=1)/n_substeps
                    for s in range(numsol):
                        MQ[1, i+1, q, s] += np.sum(mQn[:k+1, q, s], axis=0)/n_substeps
                        MQ[2:max_age+1, i+1, q, s] += np.sum(np.reshape(mQn[k+1:M-(n_substeps-k-1), q, s],(max_age-1,n_substeps)), axis=1)/n_substeps
                for s in range(numsol):
                    MR[1, i+1, s] += np.sum(mRn[:k+1, s], axis=0)/n_substeps
                    MR[2:max_age+1, i+1, s] += np.sum(np.reshape(mRn[k+1:M-(n_substeps-k-1), s],(max_age-1,n_substeps)), axis=1)/n_substeps
        if full_outputs:
            _debug(' Storing the result')
            _debug('  Water')
            ST[:max_age+1, i+1] = STn[:M+1:n_substeps]
            PQ[:,i+1,:] = np.cumsum(PQ[:,i+1,:], axis=0)
            _debug('  WaterBalance')
            WaterBalance[1:max_age, i] = np.diff(ST[0:max_age, i])-np.diff(ST[1:max_age+1, i+1]) - dt * np.dot(Q[i,:], np.diff(PQ[1:,i+1,:],axis=0).T)
            WaterBalance[0, i] = J[i] * dt - ST[1, i+1] - dt * np.dot(Q[i,:], PQ[1,i+1,:] - PQ[0,i+1,:])
            if numsol>0:
                _debug('  Solutes')
                MS[:max_age+1, i+1, :] = np.r_[np.zeros((1,numsol)), np.cumsum(mSn, axis=0)][:M+1:n_substeps]
                MR[:,i+1,:] = np.cumsum(MR[:,i+1,:], axis=0)
                MQ[:,i+1,:,:] = np.cumsum(MQ[:,i+1,:,:], axis=0)
                for s in range(numsol):
                    for q in range(numflux):
                        C_Q[i,q,s] += alpha[i,q,s] * C_old[s] * (1 - PQ[max_age, i+1, q])
                for s in range(numsol):
                    _debug('  SolutesBalance')
                    SoluteBalance[1:max_age,i,s] = (np.diff(MS[0:max_age,i,s], axis=0) - np.diff(MS[1:max_age+1,i+1,s], axis=0)
                                                    + dt * np.diff(MR[1:,i+1,s], axis=0)
                                                    - dt * np.sum(np.diff(MQ[1:,i+1,:,s], axis=0), axis=1))
                    SoluteBalance[0,i,s] = C_J[i,s] * J[i] * dt - MS[1,i+1,s] - dt * np.sum(MQ[1,i+1,:,s] - MQ[0,i+1,:,s]) + dt * np.sum(MR[1,i+1,s] - MR[0,i+1,s])
            _debug('\n')
        if np.mod(i+1,1000)==0:
            _verbose('...done ' + str(i+1) + ' of ' + str(max_age) + ' in ' + str(time.clock() - start_time) + ' seconds')
    _verbose('...making output dict...')
    if numsol>0:
        result = {'ST':ST, 'PQ':PQ, 'WaterBalance':WaterBalance, 'MS':MS, 'MQ':MQ, 'MR':MR, 'C_Q':C_Q, 'SoluteBalance':SoluteBalance}
    else:
        result = {'ST':ST, 'PQ':PQ, 'WaterBalance':WaterBalance}
    _verbose('...done.')
    return result
