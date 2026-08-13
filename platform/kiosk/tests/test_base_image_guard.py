"""Promise: the platform will only ever build apps FROM trusted base images.

A user (or the LLM writing their Dockerfile) cannot get the platform to pull and
run an arbitrary image on the build host. These are the cases a careful reviewer
would want to never regress — including the two bypasses found in code review.
"""
import pytest

from app import baseimages


@pytest.mark.parametrize("dockerfile", [
    "FROM node:20-slim",
    "FROM python:3.12-slim",
    "FROM gcr.io/distroless/nodejs",
    "FROM docker.io/library/python:3.12",
    # A normal multi-stage build: real base + a reference to an earlier stage.
    "FROM node:20 AS build\nRUN npm ci\nFROM gcr.io/distroless/nodejs\nCOPY --from=build /app /app",
    "FROM node:20 AS builder\nFROM builder",
])
def test_legitimate_base_images_are_allowed(dockerfile):
    ok, why = baseimages.validate(dockerfile)
    assert ok, f"expected allowed, got rejected: {why}"


@pytest.mark.parametrize("dockerfile", [
    # Look-alike registries that merely START with an allowed family name —
    # the `startswith` bypass. These must be rejected.
    "FROM node.evil.com/backdoor:latest",
    "FROM node-pwn/malware",
    "FROM pythonista.attacker.io/x",
    "FROM nodefake",
    "FROM nodesource/nsolid:latest",
    # A bare, untagged image that is NOT a declared build stage — the
    # stage-alias bypass. `redis`/`golang` are not on the allow-list.
    "FROM redis",
    "FROM golang",
    # Outright unlisted.
    "FROM evil/python",
])
def test_untrusted_base_images_are_rejected(dockerfile):
    ok, _ = baseimages.validate(dockerfile)
    assert not ok, f"SECURITY: untrusted base image was allowed: {dockerfile!r}"


def test_a_dockerfile_with_no_from_is_rejected():
    ok, _ = baseimages.validate("RUN echo hi\n")
    assert not ok
