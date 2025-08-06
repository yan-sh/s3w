{ mkDerivation, aeson, base, base64-bytestring, binary, bytestring
, case-insensitive, conduit, conduit-extra, crypton-connection
, cryptonite, cryptonite-conduit, data-default-class, digest
, directory, fetchgit, filepath, http-client, http-client-tls
, http-conduit, http-types, ini, lib, memory, network-uri
, QuickCheck, raw-strings-qq, relude, resourcet, retry, tasty
, tasty-hunit, tasty-quickcheck, tasty-smallcheck, text, time
, time-units, transformers, unliftio, unliftio-core
, unordered-containers, xml-conduit
}:
mkDerivation {
  pname = "minio-hs";
  version = "1.7.0";
  src = fetchgit {
    url = "https://github.com/yan-sh/minio-hs.git";
    sha256 = "0hpn9k3qf3hkbxj1llji5bw0n6q801gyvs4qh65xgzr75ik7gn5r";
    rev = "b4986b31284ef54d12da75565618c41039e3f808";
    fetchSubmodules = true;
  };
  isLibrary = true;
  isExecutable = true;
  libraryHaskellDepends = [
    aeson base base64-bytestring binary bytestring case-insensitive
    conduit conduit-extra crypton-connection cryptonite
    cryptonite-conduit data-default-class digest directory filepath
    http-client http-client-tls http-conduit http-types ini memory
    network-uri relude resourcet retry text time time-units
    transformers unliftio unliftio-core unordered-containers
    xml-conduit
  ];
  testHaskellDepends = [
    aeson base base64-bytestring binary bytestring case-insensitive
    conduit conduit-extra crypton-connection cryptonite
    cryptonite-conduit data-default-class digest directory filepath
    http-client http-client-tls http-conduit http-types ini memory
    network-uri QuickCheck raw-strings-qq relude resourcet retry tasty
    tasty-hunit tasty-quickcheck tasty-smallcheck text time time-units
    transformers unliftio unliftio-core unordered-containers
    xml-conduit
  ];
  homepage = "https://github.com/minio/minio-hs#readme";
  description = "A MinIO Haskell Library for Amazon S3 compatible cloud storage";
  license = lib.licenses.asl20;
}
