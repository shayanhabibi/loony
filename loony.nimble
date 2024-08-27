version = "0.3.0"
author = "cabboose"
description = "Fast mpmc queue with sympathetic memory behavior"
license = "MIT"

requires "https://github.com/nim-works/arc < 1.0.0"

task test, "run tests for ci":
  when defined(windows):
    exec """env GITHUB_ACTIONS="false" balls.cmd"""
  else:
    exec """env GITHUB_ACTIONS="false" balls"""
