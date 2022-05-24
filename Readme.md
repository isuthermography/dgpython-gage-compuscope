# dgpython-gage-compuscope
This is a Dataguzzler-Python module to support Vitrek GaGe digitizers using the
GaGe SDK.  Please note that a license for the GaGe SDK is required to use this
module and the GaGe SDK must be installed on your computer in order to build
this module.  This module is only provided as source code and binaries are not
distributed.  

## Prerequisites
The GaGe SDK is required.  See [here](https://www.gage-applied.com/data-acquisition/software/software-development-kits.htm) for more information.

The following Python modules are required:

- dataguzzler-python
- spatialnde2
- numpy
- pint

Additionally, on Windows, you must have Visual Studio Build Tools, Visual Studio,
or the Windows SDK installed.  Cygwin and MinGW are NOT supported.  See 
[here](https://wiki.python.org/moin/WindowsCompilers) for supported compiler versions
on Windows.

Linux requires GCC and standard build tools.

## Build Instructions
1. Begin by ensuring the CompuScope SDK is installed and in the required location. You may need to modify setup.py to ensure the SDK is found by the compiler.  Update lines 27-28 and 37-38 in setup.py as needed.  No modifications should be required on Linux.
2. `python setup.py build`
3. `python setup.py install`

## Demo
There is a demo dgp file located in the demos folder that can be used to test the
module.  Simply run `dataguzzler-python compuscope.dgp` from the demos folder.