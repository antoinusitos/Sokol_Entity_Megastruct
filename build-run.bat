@echo off

rem https://github.com/floooh/sokol-tools/blob/master/docs/sokol-shdc.md
sokol-shdc -i source/shader.glsl -o source/shader.odin -l hlsl5:wgsl -f sokol_odin

odin build source -debug

source.exe