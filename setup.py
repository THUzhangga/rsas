# -*- coding: utf-8 -*-
"""
Created on Tue Jan 14 17:57:18 2014

@author: ciaran
"""

try:
    from setuptools import setup
except ImportError:
    from distutils.core import setup
from distutils.extension import Extension
from Cython.Distutils import build_ext
import numpy

config = {
    'description': 'Time-variable transport using storage selection (SAS) functions',
    'author': 'Ciaran J. Harman',
    'url': '',
    'download_url': '',
    'author_email': 'charamn1@jhu.edu',
    'version': '0.1.1',
    'install_requires': ['nose', 'numpy', 'scipy', 'cython'],
    'packages' : ['rsas'],
    'scripts': [],
    'name': 'rsas',
    'ext_modules': [Extension('main', ['./pyrex/main.pyx'], include_dirs=[numpy.get_include()], libraries=["m"])],
    'cmdclass' : { 'build_ext': build_ext }
}
 
setup(**config)

