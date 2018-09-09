import os
import os.path
import numpy as np
from numpy.distutils.core import setup as numpy_setup
from Cython.Build import cythonize
import dataguzzler_python

# SETUP:
#  * Must install GAGE sdk and copy contents of its Include/Public directory
#    into /usr/local/include/

ext_modules=cythonize("dgpython_gage_compuscope/*.pyx")

emdict=dict([ (module.name,module) for module in ext_modules])
cs_lowlevel_ext = emdict["dgpython_gage_compuscope.cs_lowlevel"]
cs_lowlevel_ext.include_dirs.append(np.get_include())
cs_lowlevel_ext.include_dirs.append("/usr/local/dataguzzler-lib/include")
cs_lowlevel_ext.include_dirs.append("/usr/local/dataguzzler/include")
cs_lowlevel_ext.include_dirs.append(os.path.split(dataguzzler_python.__file__)[0])
cs_lowlevel_ext.library_dirs.append("/usr/local/dataguzzler-lib/lib")
cs_lowlevel_ext.library_dirs.append("/usr/local/dataguzzler/lib/dg_internal")
cs_lowlevel_ext.library_dirs.append("/usr/local/include")
cs_lowlevel_ext.libraries.extend([ "dg_internal", "dg_comm", "dataguzzler", "dg_units","CsSsm"])
cs_lowlevel_ext.extra_link_args.extend(["-g","-shared-libgcc","-lrt","-lgcc","-lpthread","-Wl,-rpath,/usr/local/dataguzzler/lib/dg_internal,-rpath,/usr/local/dataguzzler-lib/lib","-Xlinker","--export-dynamic"])

cs_lowlevel_ext.extra_compile_args.extend(["-g","-O0"])

numpy_setup(name="dgpython_gage_compuscope",
            description="GAGE CompuScope module for dgpython",
            author="Stephen D. Holland",
            url="http://thermal.cnde.iastate.edu",
            ext_modules=ext_modules,
            packages=["dgpython_gage_compuscope"])
