#!/bin/bash

(nix-build > /dev/null) && echo $(./result/bin/s3w --version)
