import sys
import os
import numpy as np
import signal

from limatix.dc_value import numericunitsvalue as nuv


# Receiving signals makes CompuScope library malfunction, so block them from the thread for this Module
signal.pthread_sigmask(signal.SIG_BLOCK,(signal.SIGFPE,signal.SIGCHLD))

# Temporary hack until all needed symbols are in a separate dll...
sys.setdlopenflags(os.RTLD_GLOBAL|os.RTLD_NOW)

from dataguzzler_python import dgpy
from dataguzzler_python.dgpy import u


from dataguzzler_python import dgold
from dataguzzler_python.dgold import cmd as dgcmd
from dataguzzler_python.dgold import DataguzzlerError


dgold.library("wfmstore.so")
dgold.library("metadata.so")
dgold.library("dio8bit.so")
dgold.library("dglink.so")
dgold.library("fftwlink.so"," nthreads=4\n fftw_estimate\n")

from dataguzzler_python import savewfm  # must be AFTER wfmstore.so library is loaded 

from dgpython_gage_compuscope.cs import CompuScope
from dgpython_gage_compuscope import gageconstants as gc


TIME=dgold.DGModule("TIME","posixtime.so","")
WFM=dgold.DGModule("WFM","wfmio.so","")

AUTH=dgold.DGModule("AUTH","auth.so",r"""
        AuthCode(localhost) = "xyzzy"
	AuthCode(127.0.0.1/32) = "xyzzy"
	AuthCode([::1]/128) = "xyzzy"
""")

stdmathinit=open("/usr/local/dataguzzler/conf/m4/stdinit.pymathm4","r").read()
stdmathfunc=open("/usr/local/dataguzzler/conf/m4/stdfunc.pymathm4","r").read()

#MATH=dgold.DGModule("MATH","wfmmath.so",r""" 
"""  numthreads = 4 # -1 would mean use number of CPU's + 1 
  #debugmode=true
 
  pymath {
    # Support Python-based math functions
    %s
    %s 

    # (can add custom math functions here)
  }

"""
#""" % (stdmathinit,stdmathfunc))


CS=CompuScope(0,0,0,0)

