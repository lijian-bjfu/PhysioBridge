export PYLSL_LIB="/Applications/LabRecorder.app/Contents/Frameworks/liblsl.2.dylib"
export DYLD_LIBRARY_PATH="/Applications/LabRecorder.app/Contents/Frameworks:${DYLD_LIBRARY_PATH}"
python3 /Users/lijian/Desktop/GitHub/polar_bridge/send_markers.py