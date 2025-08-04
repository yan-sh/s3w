{ mkDerivation, aeson, base, bytestring, co-log-core, containers
, lib, string-conv, text
}:
mkDerivation {
  pname = "co-log-json";
  version = "0.1.0.2";
  src = ./co-log-json;
  libraryHaskellDepends = [
    aeson base bytestring co-log-core containers string-conv text
  ];
  description = "Structured messages support in co-log ecosystem";
  license = lib.licenses.mpl20;
}
