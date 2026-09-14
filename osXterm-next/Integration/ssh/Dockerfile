FROM ubuntu:24.04

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends openssh-client openssh-server openssh-sftp-server netcat-openbsd \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --shell /bin/bash osxterm \
    && echo 'osxterm:osxterm' | chpasswd \
    && mkdir -p /run/sshd /home/osxterm/.ssh \
    && chown -R osxterm:osxterm /home/osxterm/.ssh \
    && chmod 700 /home/osxterm/.ssh

COPY entrypoint.sh /usr/local/bin/osxterm-sshd
RUN chmod 755 /usr/local/bin/osxterm-sshd

EXPOSE 2222
ENTRYPOINT ["/usr/local/bin/osxterm-sshd"]
