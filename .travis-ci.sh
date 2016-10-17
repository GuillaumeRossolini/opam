#!/bin/bash -xue

OPAMBSVERSION=1.2.2
OPAMBSROOT=$HOME/.opam.bootstrap
PATH=~/local/bin:$PATH; export PATH

TARGET="$1"; shift

case "$TARGET" in
    prepare)
        mkdir -p ~/local/bin
        wget -q -O ~/local/bin/opam \
             "https://github.com/ocaml/opam/releases/download/opam-$OPAMBSVERSION-$(uname -m)-$(uname -s)"
        exit 0
        ;;
    install)
        opam init --root=$OPAMBSROOT --yes --no-setup --compiler=$OCAML_VERSION
        if [ "$OPAM_TEST" = "1" ]; then
            opam install --root=$OPAMBSROOT ocamlfind lwt.2.5.2 cohttp.0.20.2 ssl cmdliner dose.3.3 jsonm
        fi
        exit 0
        ;;
    build)
        ;;
    *)
        echo "bad command $TARGET"; exit 1
esac

eval $(opam config env --root=$OPAMBSROOT)

OCAMLV=$(ocaml -vnum)
echo === OCaml version $OCAMLV ===
if [ "$OCAMLV" != "$OCAML_VERSION" ]; then
    echo "OCaml version doesn't match: travis script needs fixing"
    exit 12
fi

export OPAMYES=1
export OCAMLRUNPARAM=b


if [ "$OPAM_TEST" = "1" ]; then
    # Compile OPAM using the system libraries (install them using OPAM)
    # ignore the warnings

    echo "Bootstrapping for opam with:"
    opam config report

    eval `opam config env`

    ./configure --prefix ~/local

    make
    make install

    # Reset the bootstrapping opam root
    eval $(opam config env --root ~/.opam)

    make libinstall prefix=$(opam config var prefix)

    # Compile and run opam-rt
    wget https://github.com/ocaml/opam-rt/archive/$TRAVIS_PULL_REQUEST_BRANCH.tar.gz -O opam-rt.tar.gz || \
    wget https://github.com/ocaml/opam-rt/archive/master.tar.gz -O opam-rt.tar.gz
    tar xvfz opam-rt.tar.gz
    cd opam-rt-*
    make
    OPAMEXTERNALSOLVER=$EXTERNAL_SOLVER make KINDS="local git" run
else
    # Compile OPAM from sources and run the basic tests
    ./configure
    make lib-ext
    make
    make opam-check

    # Git should be configured properly to run the tests
    git config --global user.email "travis@example.com"
    git config --global user.name "Travis CI"

    make tests > tests.log 2>&1 || (tail -1000 tests.log && exit 1)
    # Let's see basic tasks works
    sudo make install
    opam init
    opam install lwt
    opam list
fi
