# syntax=docker/dockerfile:1.4
FROM postgres:14 as builder

# Install build dependencies
RUN apt-get update && apt-get install -y \
    git \
    build-essential \
    postgresql-server-dev-14 \
    libreadline-dev \
    zlib1g-dev \
    flex \
    bison

# Clone and build Apache AGE
RUN git clone https://github.com/apache/age.git /tmp/age && \
    cd /tmp/age && \
    git checkout release/PG14/1.4.0 && \
    make install

# Final stage
FROM postgres:14

# Install runtime dependencies
RUN apt-get update && apt-get install -y \
    openssl \
    sudo

# Copy AGE installation from builder
COPY --from=builder /usr/lib/postgresql/14/lib/age.so /usr/lib/postgresql/14/lib/
COPY --from=builder /usr/share/postgresql/14/extension/age* /usr/share/postgresql/14/extension/

# Allow the postgres user to execute certain commands as root without a password
RUN echo "postgres ALL=(root) NOPASSWD: /usr/bin/mkdir, /bin/chown, /usr/bin/openssl" > /etc/sudoers.d/postgres

# Add init scripts while setting permissions
COPY --chmod=755 init-ssl.sh /docker-entrypoint-initdb.d/init-ssl.sh
COPY --chmod=755 init-age.sh /docker-entrypoint-initdb.d/init-age.sh
COPY --chmod=755 init-graph-functions.sh /docker-entrypoint-initdb.d/init-graph-functions.sh
COPY --chmod=755 init-taxonomy-functions.sh /docker-entrypoint-initdb.d/init-taxonomy-functions.sh
COPY --chmod=755 init-ontology-functions.sh /docker-entrypoint-initdb.d/init-ontology-functions.sh
COPY --chmod=755 wrapper.sh /usr/local/bin/wrapper.sh

ENTRYPOINT ["wrapper.sh"]
CMD ["postgres", "--port=5432"] 