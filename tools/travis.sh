#!/usr/bin/env bash


travis_install_on_linux () {
    # Install OCaml and OPAM PPAs
    export ppa=avsm/ocaml42+opam12

    echo "yes" | sudo add-apt-repository ppa:$ppa
    sudo apt-get update -qq

    # Need Postgres for Ketrew
    
    sudo killall postgres
    sudo apt-get install libpq-dev postgresql-9.4

    export opam_init_options="--comp=$OCAML_VERSION"
    sudo apt-get install -qq  opam time git
}

travis_install_on_osx () {
    curl -OL "http://xquartz.macosforge.org/downloads/SL/XQuartz-2.7.6.dmg"
    sudo hdiutil attach XQuartz-2.7.6.dmg
    sudo installer -verbose -pkg /Volumes/XQuartz-2.7.6/XQuartz.pkg -target /

    brew update
    brew install opam
    export opam_init_options="--comp=$OCAML_VERSION"
}

case $TRAVIS_OS_NAME in
  osx) travis_install_on_osx ;;
  linux) travis_install_on_linux ;;
  *) echo "Unknown $TRAVIS_OS_NAME"; exit 1
esac

# configure and view settings
export OPAMYES=1
echo "ocaml -version"
ocaml -version
echo "opam --version"
opam --version
echo "git --version"
git --version

# install OCaml packages
opam init $opam_init_options
eval `opam config env`

opam update

# Cf. https://github.com/mirleft/ocaml-nocrypto/issues/104
opam pin add oasis 0.4.6

opam pin add -n ketrew https://github.com/hammerlab/ketrew.git
opam pin add -n biokepi https://github.com/hammerlab/biokepi.git

opam pin add epidisco --yes .
opam install --yes epidisco

echo "Setting Warn-Error for the Travis test"
export OCAMLPARAM="warn-error=A,_"

omake clean
omake build-all

