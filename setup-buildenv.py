#!/usr/bin/env python3

# Copyright (C) 2015 Jolla Oy
# Contact: Jussi Pakkanen <jussi.pakkanen@jolla.com>
# All rights reserved.
#
# You may use this file under the terms of BSD license as follows:
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#   * Redistributions of source code must retain the above copyright
#     notice, this list of conditions and the following disclaimer.
#   * Redistributions in binary form must reproduce the above copyright
#     notice, this list of conditions and the following disclaimer in the
#     documentation and/or other materials provided with the distribution.
#   * Neither the name of the Jolla Ltd nor the
#     names of its contributors may be used to endorse or promote products
#     derived from this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR CONTRIBUTORS BE LIABLE FOR
# ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
# (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
# LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
# ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
# SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

# Download and extract all source dependencies that we have.
# Run this in ~/invariant (or C:\invariant on Windows).

# Must match DEF_QT_VER in defaults.sh
QT_VER = '5.15.14'

import platform
import os, sys
import urllib.request
import shutil
import subprocess
import tarfile, zipfile

downloads = [
    ('https://download.qt.io/archive/qt/5.15/%s/single/qt-everywhere-src-%s.tar.xz' % (QT_VER, QT_VER),
     'qt-everywhere-src-%s.tar.xz' % QT_VER,
     'qt-everywhere-src-%s' % QT_VER),
    ]

if platform.system() == 'Linux':
    downloads.append(('http://download.icu-project.org/files/icu4c/4.2.1/icu4c-4_2_1-src.tgz', 'icu4c-4_2_1-src.tgz', 'icu'))
elif platform.system() == 'Windows':
    downloads.append(('http://download.icu-project.org/files/icu4c/4.8.1.1/icu4c-4_8_1_1-Win32-msvc10.zip', 'icu4c-4_8_1_1-Win32-msvc10.zip', 'icu'))
elif platform.system() == 'Darwin':
    pass # OSX does not need ICU.
else:
    print('Unknown platform:', platform.system())
    sys.exit(1)

for d in downloads:
    (url, fname, dirname) = d
    try:
        os.unlink(fname)
    except Exception:
        pass
    print('Downloading', url)
    urllib.request.urlretrieve(url, fname)
    shutil.rmtree(dirname, ignore_errors=True)
    if fname.endswith('.zip'):
        tf = zipfile.ZipFile(fname, 'r')
    else:
        tf = tarfile.open(fname)
    print('Extracting', fname)
    tf.extractall()

# Installer Framework is fetched from git because the Sailfish OS fork does
# not publish source tarballs. This matches DEF_IFW_SRC_DIR in defaults.sh.
if not os.path.isdir('qt-installer-framework'):
    print('Cloning qt-installer-framework')
    subprocess.check_call(['git', 'clone',
                           'https://github.com/sailfishos/qt-installer-framework.git',
                           'qt-installer-framework'])

if platform.system() == 'Linux':
    print('''You need to install platform build dependencies by hand. On
Debian-derivatives this means running the following commands:

sudo apt-get install build-essential pkg-config chrpath
sudo apt-get install "^libxcb.*" libx11-xcb-dev libglu1-mesa-dev libxrender-dev libxi-dev
sudo apt-get install flex bison gperf libicu-dev libxslt-dev ruby''')
elif platform.system() == 'Darwin':
    print('''You need to install platform build dependencies by hand. On
macOS this means installing Xcode command line tools and, via Homebrew:

brew install p7zip cmake''')
