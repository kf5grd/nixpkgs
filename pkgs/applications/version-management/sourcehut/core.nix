{ lib
, fetchgit
, fetchNodeModules
, buildPythonPackage
, pgpy
, flask
, bleach
, misaka
, humanize
, html5lib
, markdown
, psycopg2
, pygments
, requests
, sqlalchemy
, cryptography
, beautifulsoup4
, sqlalchemy-utils
, prometheus-client
, celery
, alembic
, importlib-metadata
, mistletoe
, minio
, sassc
, nodejs
, redis
, writeText
}:

buildPythonPackage rec {
  pname = "srht";
  version = "0.67.25";

  src = fetchgit {
    url = "https://git.sr.ht/~sircmpwn/core.sr.ht";
    rev = version;
    sha256 = "sha256-JZXIpNEY1/KUaYh0Vk5j/zVO9JQc2F1RmnZ/5TFN0PI=";
    fetchSubmodules = true;
  };

  node_modules = fetchNodeModules {
    src = "${src}/srht";
    nodejs = nodejs;
    sha256 = "sha256-IWKahdWv3qJ5DNyb1GB9JWYkZxghn6wzZe68clYXij8=";
  };

  patches = [
    ./disable-npm-install.patch
  ];

  nativeBuildInputs = [
    sassc
    nodejs
  ];

  propagatedBuildInputs = [
    pgpy
    flask
    bleach
    misaka
    humanize
    html5lib
    markdown
    psycopg2
    pygments
    requests
    mistletoe
    sqlalchemy
    cryptography
    beautifulsoup4
    sqlalchemy-utils
    prometheus-client

    # Unofficial runtime dependencies?
    celery
    alembic
    importlib-metadata
    minio
    redis
  ];

  PKGVER = version;

  preBuild = ''
    cp -r ${node_modules} srht/node_modules
  '';

  dontUseSetuptoolsCheck = true;
  pythonImportsCheck = [ "srht" ];

  meta = with lib; {
    homepage = "https://git.sr.ht/~sircmpwn/srht";
    description = "Core modules for sr.ht";
    license = licenses.bsd3;
    maintainers = with maintainers; [ eadwu ];
  };
}
