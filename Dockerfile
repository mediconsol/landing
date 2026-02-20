FROM nginx:alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY index.html /usr/share/nginx/html/index.html
COPY favicon.ico /usr/share/nginx/html/favicon.ico
COPY favicon.svg /usr/share/nginx/html/favicon.svg
COPY favicon.png /usr/share/nginx/html/favicon.png
COPY apple-touch-icon.png /usr/share/nginx/html/apple-touch-icon.png
COPY og-image.png /usr/share/nginx/html/og-image.png
EXPOSE 80
