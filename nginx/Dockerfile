# ---- Employee Management System - Nginx image ----

# Build context is the REPO ROOT
# This allows the Dockerfile to access frontend/ and nginx/

FROM nginx:1.27-alpine

RUN apk add --no-cache curl \
    && rm -rf /usr/share/nginx/html/*

COPY frontend/ /usr/share/nginx/html/
COPY nginx/nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -fsS http://localhost/ || exit 1

CMD ["nginx", "-g", "daemon off;"]
