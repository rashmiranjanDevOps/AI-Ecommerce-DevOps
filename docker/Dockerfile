# Nexvion web image: static site served by an unprivileged Nginx.
# Build from the repository root:
#   docker build -f docker/Dockerfile -t nexvion-web:local .
FROM nginxinc/nginx-unprivileged:1.29-alpine

ARG APP_VERSION=dev
ARG VCS_REF=unknown
LABEL org.opencontainers.image.title="nexvion-web" \
      org.opencontainers.image.description="Nexvion e-commerce front end served by Nginx" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.vendor="Davine Technologies (internship project)"

# Patch OS packages, then drop back to the unprivileged user.
USER root
RUN apk upgrade --no-cache \
 && rm -rf /usr/share/nginx/html/* /etc/nginx/conf.d/default.conf \
 && mkdir -p /etc/nginx/auth.d
USER nginx

COPY --chown=nginx:nginx docker/nginx/default.conf /etc/nginx/conf.d/default.conf
COPY --chown=nginx:nginx application/ /usr/share/nginx/html/

# Version marker, readable at /version.txt
RUN echo "${APP_VERSION} ${VCS_REF}" > /usr/share/nginx/html/version.txt

EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8080/health || exit 1
