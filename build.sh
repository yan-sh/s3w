#!/bin/bash

nix-build docker.nix --argstr version $VERSION --argstr registry registry.cloud.gruzchiki.ru
