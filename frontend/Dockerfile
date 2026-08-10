# ---- Employee Management System - AKS frontend image ----
# Serves ONLY the static frontend (HTML/CSS/JS). This is a *deployment*
# artifact difference from the VM setup, not an application code change:
# the same index.html/css/js used by the VM's Nginx container are reused
# here unmodified - only the container that serves them differs, because
# in AKS the Ingress (not this container) handles /api routing.
#
# Base image: nginx-unprivileged already runs as a non-root user and
# listens on port 8080 by default, so it works cleanly with Kubernetes
# Pod securityContext (runAsNonRoot, readOnlyRootFilesystem, etc.)
# without extra permission hacks.
FROM nginxinc/nginx-unprivileged:1.27-alpine

COPY --chown=nginx:nginx index.html /usr/share/nginx/html/index.html
COPY --chown=nginx:nginx css/ /usr/share/nginx/html/css/
COPY --chown=nginx:nginx js/ /usr/share/nginx/html/js/
COPY --chown=nginx:nginx nginx.aks.conf /etc/nginx/conf.d/default.conf

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget -qO- http://localhost:8080/health || exit 1

CMD ["nginx", "-g", "daemon off;"]
