FROM ubuntu:24.04

# sshd plus the two demo accounts used by the RBAC use case.
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends openssh-server \
 && rm -rf /var/lib/apt/lists/* \
 && useradd -m -s /bin/bash developer \
 && useradd -m -s /bin/bash deployer \
 && mkdir -p /run/sshd /etc/ssh/auth_principals

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 22
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
