FROM nginx:alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY .htpasswd /etc/nginx/.htpasswd
COPY index.html /usr/share/nginx/html/index.html
COPY favicon.ico /usr/share/nginx/html/favicon.ico
COPY favicon.svg /usr/share/nginx/html/favicon.svg
COPY logo.svg /usr/share/nginx/html/logo.svg
COPY og-image.png /usr/share/nginx/html/og-image.png
EXPOSE 80
