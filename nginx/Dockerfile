# Construir desde la raiz del repo:  docker build -f nginx/Dockerfile -t <repo>:nginx .
FROM nginx:alpine

# Por defecto el API vive en el mismo task de ECS (localhost).
ENV API_HOST=127.0.0.1

COPY frontend/ /usr/share/nginx/html/
COPY nginx/default.conf.template /etc/nginx/templates/default.conf.template

EXPOSE 80
