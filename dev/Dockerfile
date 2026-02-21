FROM alpine:3.20

RUN apk add --no-cache \
    cgit \
    lighttpd lighttpd-mod_auth \
    git git-daemon \
    py3-pygments \
    py3-markdown \
    lua5.3-libs \
    && rm -rf /var/cache/apk/*

# Alpine cgit paths:
#   CGI binary:  /usr/share/webapps/cgit/cgit.cgi
#   Assets:      /usr/share/webapps/cgit/{cgit.css,cgit.png,favicon.ico,robots.txt}
#   Filters:     /usr/lib/cgit/filters/
#   HTTP backend:/usr/libexec/git-core/git-http-backend  (from git-daemon pkg)
#
# Our lighttpd config expects everything under /usr/share/cgit/,
# so create that directory and symlink the CGI binary + HTTP backend.
RUN mkdir -p /usr/share/cgit \
    && ln -sf /usr/share/webapps/cgit/cgit.cgi /usr/share/cgit/cgit.cgi \
    && ln -sf /usr/libexec/git-core/git-http-backend /usr/share/cgit/git-http-backend

# Create runtime directories
RUN mkdir -p /srv/git /var/cache/cgit /etc/cgit /var/log/lighttpd \
    && chown -R lighttpd:lighttpd /var/cache/cgit

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8080

ENTRYPOINT ["/entrypoint.sh"]
