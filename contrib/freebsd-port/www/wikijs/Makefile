PORTNAME=	wikijs
PORTVERSION=	2.5.314
CATEGORIES=	www
MASTER_SITES=	https://github.com/Requarks/wiki/archive/refs/tags/

MAINTAINER=	mark@cloudbsd.org
COMMENT=	Modern, lightweight and powerful wiki app built on Node.js
WWW=		https://js.wiki/

LICENSE=	AGPLv3
LICENSE_FILE=	${WRKSRC}/LICENSE

USES=		gmake nodejs:24 shebangfix
USE_GITHUB=	yes
GH_ACCOUNT=	Requarks
GH_PROJECT=	wiki
GH_TAGNAME=	v${PORTVERSION}

USE_RC_SUBR=	${PORTNAME}
SUB_FILES=	wikijs-wrapper pkg-message config.sample

WIKIJS_USER=	${PORTNAME}
WIKIJS_GROUP=	${PORTNAME}

USERS=		${WIKIJS_USER}
GROUPS=		${WIKIJS_GROUP}

WIKIJS_ETC_DIR=		${PREFIX}/etc/${PORTNAME}
WIKIJS_DATA_DIR=	/var/db/${PORTNAME}
WIKIJS_LOG_DIR=		/var/log/${PORTNAME}
WIKIJS_RUN_DIR=		/var/run/${PORTNAME}
WWWDIR=			${PREFIX}/www/${PORTNAME}

SUB_LIST+=	WIKIJS_USER=${WIKIJS_USER} \
		WIKIJS_GROUP=${WIKIJS_GROUP} \
		WIKIJS_DATA_DIR=${WIKIJS_DATA_DIR} \
		WIKIJS_LOG_DIR=${WIKIJS_LOG_DIR} \
		WIKIJS_RUN_DIR=${WIKIJS_RUN_DIR} \
		WIKIJS_ETC_DIR=${WIKIJS_ETC_DIR}

OPTIONS_SINGLE=		DB
OPTIONS_SINGLE_DB=	SQLITE PGSQL MARIADB
OPTIONS_DEFAULT=	SQLITE

# Touch each option so portlint does not complain about unreferenced
# OPTIONS_DEFINE entries; the selection itself is consumed by the
# PGSQL_RUN_DEPENDS / MARIADB_RUN_DEPENDS hooks below.
OPTIONS_SUB=	yes

SQLITE_DESC=		Use SQLite (no external database required)
PGSQL_DESC=		Use PostgreSQL as the database backend
MARIADB_DESC=		Use MariaDB as the database backend

# When a DB option other than SQLITE is selected, depend on the matching
# client binary so users get a clear error if the server is missing.
# The version-suffixed names are resolved against DEFAULT_VERSIONS in
# /etc/make.conf (e.g. DEFAULT_VERSIONS+= mariadb=11.4).
#
# MySQL is intentionally not offered as an option -- use MariaDB
# instead.  MariaDB is a drop-in replacement for MySQL with an active
# upstream and a maintained FreeBSD port.
PGSQL_RUN_DEPENDS=	${LOCALBASE}/bin/psql:databases/postgresql${PGSQL_DEFAULT}-client
MARIADB_RUN_DEPENDS=	${LOCALBASE}/bin/mysql:databases/mariadb${MARIADB_DEFAULT}-client

BUILD_DEPENDS+=	npm-node${NODEJS_VERSION}>0:www/npm-node${NODEJS_VERSION} \
		python311:lang/python311

# Wiki.js's webpack 4 toolchain and several legacy crypto paths in
# transitive dependencies still rely on the deprecated OpenSSL legacy
# provider, which Node 17+ hides by default.
#
# node-gyp 8.4.1 (transitively pulled in by sqlite3@5.1.7) imports
# distutils, which Python 3.12 dropped.  Pin Python 3.11.
MAKE_ENV+=	NODE_OPTIONS=--openssl-legacy-provider \
		PYTHON=${LOCALBASE}/bin/python3.11 \
		TMPDIR=${WRKDIR}

# The upstream patches/extract-files+9.0.0.patch is applied by
# patch-package during do-build, after `npm ci` has populated
# node_modules/.  We do NOT use EXTRA_PATCHES because the patch
# targets node_modules/extract-files/index.js which does not exist
# until after the dependencies are fetched.
#
# Cypress (dev-only, no freebsd prebuild) is handled by running
# `npm ci` with --omit=dev and --ignore-scripts in do-build; it never
# gets resolved, and its life-cycle script never fires.

# node_modules ships ~64000 files.  Generate pkg-plist dynamically so
# the port does not need to maintain a giant manifest by hand.
PLIST=		${WRKDIR}/plist
PLIST_FILES=	# empty -- bulk entries come from generated ${PLIST}

do-build:
	@${ECHO_MSG} "===>  Fetching npm dependencies (including devDependencies for the webpack build)..."
	cd ${WRKSRC} && \
		${SETENV} ${MAKE_ENV} npm install --include=dev \
			--legacy-peer-deps --ignore-scripts \
			--no-audit --no-fund --no-update-notifier
	@${ECHO_MSG} "===>  Applying upstream patches via patch-package (no-op on FreeBSD)..."
	cd ${WRKSRC} && ${SETENV} ${MAKE_ENV} npx --no-install patch-package
	@${ECHO_MSG} "===>  Rebuilding native modules for FreeBSD..."
	# We only need to force a rebuild of modules whose upstream prebuilds
	# are linux-only.  Modules that ship NAPI binaries or have portable
	# JS fallbacks (ssh2, cpu-features, bufferutil, utf-8-validate)
	# either keep their prebuilt .node file or fall back to pure JS.
	cd ${WRKSRC} && \
		${SETENV} ${MAKE_ENV} npm rebuild sqlite3 --build-from-source --no-update-notifier
	# Restore executable bit on bin scripts (npm 11 + FreeBSD quirk)
	@${FIND} ${WRKSRC}/node_modules -type f -name '*.js' \
		-path '*/bin/*' ! -perm -u+x -exec ${CHMOD} u+x {} +
	@${ECHO_MSG} "===>  Building client assets (webpack production build)..."
	cd ${WRKSRC} && ${SETENV} ${MAKE_ENV} npm run build

pre-install:
	@${ECHO_MSG} "===>  Staging Wiki.js into ${STAGEDIR}${WWWDIR}..."
	${MKDIR} ${STAGEDIR}${WWWDIR}
	cd ${WRKSRC} && ${COPYTREE_SHARE} . ${STAGEDIR}${WWWDIR} \
		"! ( -path '*/node_modules/*/test' -o \
		     -name '*.md' -path '*node_modules*' -o \
		     -name '.git*' -o \
		     -name '.editorconfig' -o \
		     -name '.eslintrc*' -o \
		     -name '*.markdown' -o \
		     -name 'LICENSE*' -path '*node_modules*' )"
	@${RM} -rf ${STAGEDIR}${WWWDIR}/dev
	@${RM} -rf ${STAGEDIR}${WWWDIR}/cypress.json ${STAGEDIR}${WWWDIR}/webpack.config.js
	@${RM} -rf ${STAGEDIR}${WWWDIR}/.devcontainer ${STAGEDIR}${WWWDIR}/.github
	@${RM} -rf ${STAGEDIR}${WWWDIR}/node_modules/.cache
	@${CHMOD} -R u+w ${STAGEDIR}${WWWDIR}
	# Drop executable bits on shipped *.js files that do not need to be
	# executable (only bin scripts do).  This is a minor security /
	# noise reduction; it does not affect runtime.
	@${FIND} ${STAGEDIR}${WWWDIR} -type f -name '*.js' \
		-perm -100 -exec ${CHMOD} a-x {} +
	# Install the wrapper, config, newsyslog, runtime dirs ALL HERE
	# in pre-install so they are present when we scan STAGEDIR for
	# the packing list.  bsd.port.mk runs `generate-plist` (stage
	# step 400) BEFORE `do-install` (step 500), and `generate-plist`
	# reads ${PLIST} verbatim.  Anything installed in do-install would
	# be missing from the manifest.
	${MKDIR} ${STAGEDIR}${PREFIX}/bin
	${INSTALL_SCRIPT} ${WRKDIR}/wikijs-wrapper ${STAGEDIR}${PREFIX}/bin/${PORTNAME}
	${MKDIR} ${STAGEDIR}${WIKIJS_ETC_DIR}
	${INSTALL_DATA} ${WRKDIR}/config.sample \
		${STAGEDIR}${WIKIJS_ETC_DIR}/config.sample.yml
	${INSTALL_DATA} ${FILESDIR}/newsyslog.conf \
		${STAGEDIR}${WIKIJS_ETC_DIR}/newsyslog.conf.sample
	${MKDIR} ${STAGEDIR}${WIKIJS_DATA_DIR}/data
	${MKDIR} ${STAGEDIR}${WIKIJS_LOG_DIR}
	${MKDIR} ${STAGEDIR}${WIKIJS_RUN_DIR}

	# Generate the packing list now, while STAGEDIR is authoritative.
	# bsd.port.mk runs `generate-plist` (stage step 400) BEFORE
	# `do-install` (step 500), so the plist must exist by the time
	# `generate-plist` reads it.  We do the heavy COPYTREE_SHARE +
	# plist generation in pre-install (step 300) and leave do-install
	# as a no-op for now.
	@${ECHO_CMD} "@owner ${WIKIJS_USER}" > ${PLIST}
	@${ECHO_CMD} "@group ${WIKIJS_GROUP}" >> ${PLIST}
	@${FIND} -s ${STAGEDIR} -type f -o -type l \
		| ${SED} -e "s|^${STAGEDIR}||" \
		| ${GREP} -v '^$$' \
		>> ${PLIST}
	@${FIND} -d ${STAGEDIR} -type d -mindepth 1 \
		| ${SED} -e "s|^${STAGEDIR}||" \
		| ${GREP} -v '^$$' \
		| ${SORT} -r \
		| ${XARGS} -I {} ${ECHO_CMD} "@dir {}" >> ${PLIST}
	@${ECHO_CMD} "@owner" >> ${PLIST}
	@${ECHO_CMD} "@group" >> ${PLIST}
	@${ECHO_MSG} "===>  Generated pkg-plist with $$(wc -l < ${PLIST}) entries."

do-install:
	@${DO_NADA}

.include <bsd.port.mk>
