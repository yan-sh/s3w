#!/bin/bash

nix-build docker.nix --argstr version v$VERSION --argstr registry registry.cloud.gruzchiki.ru \
  && echo $(podman load < result | cut -c 15-) > .image \
  && podman push --authfile=/podman-data/auth.json $(cat .image)
