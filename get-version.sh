#!/bin/bash

nix-build && echo $(./result/bin/s3w --version)
