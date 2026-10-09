# Build environment for Snapmaker Orca on Ubuntu 26.04 (resolute); packages in provision.sh.
FROM ubuntu:26.04

COPY provision.sh /tmp/provision.sh
RUN bash /tmp/provision.sh && rm /tmp/provision.sh

ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
