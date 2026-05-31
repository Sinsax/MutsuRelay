# Shared macro for all platforms.
# Include: include("${PROJECT_ROOT}/cmake/native_bundle.cmake")
#
# Usage:
#   setup_native_and_model(
#     TARGET       ${BINARY_NAME}
#     PROJECT_ROOT "${PROJECT_ROOT}"
#     MODEL_DEST   "asr/model"
#     LIB_DEST     "."
#     LIB_NAME     "mutsurelay_native.dll"
#     RUNTIME_DEPS "sherpa-onnx-c-api.dll" "sherpa-onnx-cxx-api.dll"
#   )

macro(setup_native_and_model)
  set(options "")
  set(oneValueArgs TARGET PROJECT_ROOT MODEL_DEST LIB_DEST LIB_NAME)
  set(multiValueArgs RUNTIME_DEPS)
  cmake_parse_arguments(ARG "${options}" "${oneValueArgs}" "${multiValueArgs}" ${ARGN})

  set(ASR_MODEL_DIR "${ARG_PROJECT_ROOT}/asr/model")
  set(NATIVE_DIR "${ARG_PROJECT_ROOT}/native")

  if(CMAKE_BUILD_TYPE MATCHES "Debug")
    set(CARGO_PROFILE "debug")
    set(CARGO_FLAGS "")
  else()
    set(CARGO_PROFILE "release")
    set(CARGO_FLAGS "--release")
  endif()
  set(CARGO_TARGET "${NATIVE_DIR}/target/${CARGO_PROFILE}")

  # Download ASR model on first build
  add_custom_target(download_asr_model ALL
    COMMAND ${CMAKE_COMMAND}
      -D MODEL_DIR="${ASR_MODEL_DIR}"
      -P "${ARG_PROJECT_ROOT}/cmake/download_model.cmake"
    COMMENT "Checking ASR model (downloads ~200MB if missing)..."
  )

  # Build Rust native library
  add_custom_target(rust_native ALL
    COMMAND cargo build ${CARGO_FLAGS}
    WORKING_DIRECTORY "${NATIVE_DIR}"
    COMMENT "Building Rust native library (${CARGO_PROFILE})..."
  )

  add_dependencies(${ARG_TARGET} download_asr_model rust_native)

  # Install ASR model
  install(DIRECTORY "${ASR_MODEL_DIR}/"
          DESTINATION "${ARG_MODEL_DEST}"
          COMPONENT Runtime)

  # Install native library
  install(FILES "${CARGO_TARGET}/${ARG_LIB_NAME}"
          DESTINATION "${ARG_LIB_DEST}"
          OPTIONAL COMPONENT Runtime)

  # Install runtime dependencies (sherpa-onnx, onnxruntime)
  foreach(dep ${ARG_RUNTIME_DEPS})
    install(FILES "${CARGO_TARGET}/${dep}"
            DESTINATION "${ARG_LIB_DEST}"
            OPTIONAL COMPONENT Runtime)
  endforeach()
endmacro()
