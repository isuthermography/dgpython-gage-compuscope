import sys
import os
import os.path
import numpy as np
from numpy.distutils.core import setup
from Cython.Build import cythonize
import dataguzzler_python
import distutils
import subprocess
import re

# SETUP:
#  * Must install GAGE sdk and copy contents of its Include/Public directory
#    into /usr/local/include/

ext_modules=cythonize(["dgpython_gage_compuscope/*.pyx"],
                      language_level='3str',  # Set to 3str for now until string stuff is fixed
                      emit_linenums=True) 

emdict=dict([ (module.name,module) for module in ext_modules])
cs_lowlevel_ext = emdict["dgpython_gage_compuscope.cs_lowlevel"]

cs_lowlevel_ext.include_dirs.append(np.get_include())
cs_lowlevel_ext.include_dirs.append(os.path.split(dataguzzler_python.__file__)[0])
cs_lowlevel_ext.libraries.extend(["CsSsm"])
if sys.platform == "win32":
    cs_lowlevel_ext.include_dirs.append(r"C:\Program Files (x86)\Gage\CompuScope\include")
    cs_lowlevel_ext.library_dirs.append(r"C:\Program Files (x86)\Gage\CompuScope\lib64")
    cs_lowlevel_ext.extra_compile_args.extend([r"-Zi",r"-Ox"])
    cs_lowlevel_ext.extra_link_args.extend([r"-debug:full"])
else:
    cs_lowlevel_ext.extra_compile_args.extend(["-g","-O0"])
    cs_lowlevel_ext.extra_link_args.extend(["-g","-shared-libgcc","-lrt","-lgcc","-lpthread","-Xlinker","--export-dynamic"])

gc_ext = emdict["dgpython_gage_compuscope.gc"]
if sys.platform == "win32":
    gc_ext.include_dirs.append(r"C:\Program Files (x86)\Gage\CompuScope\include")
    gc_ext.library_dirs.append(r"C:\Program Files (x86)\Gage\CompuScope\lib64")
    gc_ext.extra_compile_args.extend([r"-Zi",r"-Ox"])
    gc_ext.extra_link_args.extend([r"-debug:full"])
else:
    gc_ext.extra_compile_args.extend(["-g","-O0"])
    gc_ext.extra_link_args.extend(["-g","-shared-libgcc","-lrt","-lgcc","-lpthread","-Xlinker","--export-dynamic"])


# Extract GIT version (use subprocess.call(['git','rev-parse']) to check if we are inside a git repo
if distutils.spawn.find_executable("git") is not None and subprocess.call(['git','rev-parse'],stderr=subprocess.DEVNULL)==0:
    # Check if tree has been modified
    modified = subprocess.call(["git","diff-index","--quiet","HEAD","--"]) != 0
    
    gitrev = subprocess.check_output(["git","rev-parse","HEAD"]).decode('utf-8').strip()

    version = "git-%s" % (gitrev)

    # See if we can get a more meaningful description from "git describe"
    try:
        versionraw=subprocess.check_output(["git","describe","--tags","--match=v*"],stderr=subprocess.STDOUT).decode('utf-8').strip()
        # versionraw is like v0.1.0-50-g434343
        # for compatibility with PEP 440, change it to
        # something like 0.1.0+50.g434343
        matchobj=re.match(r"""v([^.]+[.][^.]+[.][^-.]+)(-.*)?""",versionraw)
        version=matchobj.group(1)
        if matchobj.group(2) is not None:
            version += '+'+matchobj.group(2)[1:].replace("-",".")
            pass
        pass
    except subprocess.CalledProcessError:
        # Ignore error, falling back to above version string
        pass

    if modified and version.find('+') >= 0:
        version += ".modified"
        pass
    elif modified:
        version += "+modified"
        pass
    pass
else:
    version = "UNKNOWN"
    pass



setup(name="dgpython_gage_compuscope",
            description="GAGE CompuScope module for dgpython",
            author="Stephen D. Holland",
            maintainer="Tyler Lesthaeghe",
            maintainer_email="tyler.lesthaeghe@udri.udayton.edu",
            url="http://thermal.cnde.iastate.edu",
            version=version,
            ext_modules=ext_modules,
            packages=["dgpython_gage_compuscope"],
            package_data={"dgpython_gage_compuscope": ["*.dpi"]}
        )
