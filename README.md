# Mutual Attestation PoC Implementation

This project provides a Proof of Concept implementation for a setting where several nodes attest to one another; each node verifies the others' **reference measurements** without any external source for those reference values. It employs the [PyReflect](https://github.com/acompany-develop/PyReflect) transpiler for mutual-reference programming.

## Overview

Consider two nodes, A and B, that attest to one another. Each node's attestation evidence carries a *measurement* of that node, and a verifier appraises it by comparing the measurement against a *reference value*. Conventionally, the reference values are supplied in one of two ways:

1. a trusted third party (a *Reference Value Provider*) distributes the reference measurements of A and B; or
2. each node hardcodes the reference measurement of the node(s) it is meant to verify.

Under (2), embedding each node's reference measurement into the other is self-contradicing. Writing B's measurement into A changes A's source, and hence A's measurement, which forces B to be updated, which in turn changes B's measurement, *ad infinitum*. This amounts to solving for a fixed point of the mutually-dependent hashes; assuming the hash function is computationally secure, doing so appears infeasible (though we are not aware of a proof).

This PoC avoids the infinite regress of (2) by embedding, in place of the reference measurement *value*, a function that *generates* it together with the data that function needs. Each node can then reconstruct the exact source of the other node from data carried within itself and hash it, so reference values are derived intrinsically rather than fetched from any external source (file, stdin, registry, ...). The construction is based on **Kleene's second recursion theorem**, and the mutual-reference transpilation is performed by [PyReflect](https://github.com/acompany-develop/PyReflect).

This repository demonstrates post-handshake mutual attestation backed by TPM. Two nodes performs TPM-backed mutual attestation after ECDH key exchange, including the verification of each other's reference values.

## Setup

### Option A: Dev Container (recommended)

This repository ships with a [Dev Container](https://containers.dev/). Open it in the Dev Container and all the
dependencies are installed automatically.

### Option B: Build the Docker image manually

Alternatively, build and start the `.devcontainer/Dockerfile` yourself, then install the
Python packages inside the container:

```bash
# Build the image
docker build -t mutual-ra-poc -f .devcontainer/Dockerfile .

# Start a container
docker run --rm -it -v "$PWD:/workspace" -w /workspace mutual-ra-poc bash

# Install every required Python package
uv venv
uv pip install -r requirements.txt
```

### Requirements (installed automatically in the Dev Container)

- Python >= 3.12
- [uv](https://github.com/astral-sh/uv) >= 0.11.3
- [PyReflect](https://github.com/acompany-develop/PyReflect) == 0.1.0
- [cryptography](https://github.com/pyca/cryptography) == 49.0.0
- [tpm2-pytss](https://github.com/tpm2-software/tpm2-pytss) == 2.3.1.dev69+g9d386fca1
- [swtpm](https://github.com/stefanberger/swtpm) >= 0.10.1

## Usage

```bash
# Transpile
pyreflect template.json .

# E2E test
./run.sh

# Verify
sha256sum *.py
```

Example of a successful run (AK hashes and line interleaving vary):

```console
$ ./run.sh
== bring up one swtpm per node ==
n0 (re)started -> swtpm:path=/tmp/tpm/n0.sock
n1 (re)started -> swtpm:path=/tmp/tpm/n1.sock
== run node 1 (listener, vTPM n0) in background ==
[__NODE1] listening on 127.0.0.1:30303
== run node 2 (connector, vTPM n1) ==
[__NODE1] peer ref (self-computed): 7e7ea367afd6edee8809ae280acce84d0e961dd84a3025bf3d0c28e4d35530a9
[__NODE2] peer ref (self-computed): 429046816658738eb123f3e5a7e75fe108c927ac893ce207bd22bde48df9fe4a
[__NODE2] peer AK hash (received) : <run-specific SHA-256>
[__NODE1] peer AK hash (received) : <run-specific SHA-256>
[__NODE2] PCR23 recalculated      : c592d713f803b97ef841d408d1da7d10c3c6f4756bc37759addba39afdb7bd6e
[__NODE1] PCR23 recalculated      : db786d682714ebcd3da81cddb7ad5803f629e0687901a8ca02cc6c0d76ed833e
[__NODE2] PCR23 received          : c592d713f803b97ef841d408d1da7d10c3c6f4756bc37759addba39afdb7bd6e
[__NODE1] PCR23 received          : db786d682714ebcd3da81cddb7ad5803f629e0687901a8ca02cc6c0d76ed833e
[__NODE2] peer __NODE1 : ATTESTATION VERIFIED
[__NODE2] VK and SK established
[__NODE1] peer __NODE2 : ATTESTATION VERIFIED
[__NODE1] VK and SK established
[__NODE1] peer says: 'hello from __NODE2' (AES-GCM authenticated)
[__NODE2] peer says: 'hello from __NODE1' (AES-GCM authenticated)
== done ==
```

```console
$ sha256sum *.py
429046816658738eb123f3e5a7e75fe108c927ac893ce207bd22bde48df9fe4a  node___NODE1.py
7e7ea367afd6edee8809ae280acce84d0e961dd84a3025bf3d0c28e4d35530a9  node___NODE2.py
```

### Protocol

1. Generate an ephemeral P-256 ECDH key and a 32-byte challenge nonce; exchange the nonce and the public key encoded as DER SubjectPublicKeyInfo;
2. Validate the peer public key, calculate the ECDH shared secret `Z`, and derive two distinct 32-byte keys:
   `VK = HMAC-SHA256(key=Z, data="VK")` and `SK = HMAC-SHA256(key=Z, data="SK")`;
3. In the vTPM, create an ECDSA AK, set `PCR23 = reset(0)`, and then `extend(sha256(own file))`;
4. For attester A responding to verifier B, call `Quote(PCR23)` with
   `sha256(nonce_B || pub_A || pub_B || VK)` as qualifying data. The public-key values are the exact DER bytes exchanged in step 1;
5. Exchange the AK public key, PCR value, quote, and signature;
6. Verify the peer's quote: check the signature under the peer AK,
   `extraData == sha256(my_nonce || peer_pubkey || own_pubkey || VK)`, and
   `pcrDigest == sha256(expected_pcr)`, where `expected_pcr` is replayed from the reproduced peer source code;
7. Only after successful verification, exchange messages encrypted and authenticated with AES-256-GCM under `SK`. Each message uses a fresh random 12-byte GCM nonce; the transmitted ciphertext includes the 16-byte GCM authentication tag.

One swtpm is used per node, mirroring the real target where each node runs in its own VM with its own (v)TPM; both nodes use PCR23 on their own (v)TPM.

### Notes

- The AK is uncertified here; the peer trusts the received AK. In production, the AK public key must be endorsed by the confidential VM's hardware attestation or by the hardware TPM-vendor's EK certificate.
- PCR 23 can be freely extended or reset from userland, so the value of PCR 23 is not (by itself) trustworthy. Furthermore, there is no guarantee that the code hash value stored there corresponds to the hash of the programme currently being executed. To perform a rigorous attestation, we should use the Linux Integrity Measurement Architecture to measure file hash digests, and use the IMA measurement log and PCR 10 in place of PCR 23.

## Historical Note

Kleene's second recursion theorem was proved in Kleene (1938), and the idea behind its proof can be traced back to Gödel (1931). That such self-reference can be turned into a programming technique is itself well known; familiar examples include von Neumann's self-reproducing automata, Quine (self-reproducing program), and Curry's Y-combinator in the lambda calculus.

## Reference

- IETF, RFC 9334: Remote ATtestation procedureS (RATS) Architecture.
  <https://datatracker.ietf.org/doc/rfc9334/>
- Haofan Zheng and Owen Arden (2021), Secure Distributed Applications the Decent Way. In *Proceedings of the 2021 International Symposium on Advanced Security on Software and Systems (ASSS '21)*, Association for Computing Machinery, New York, NY, USA, 29–42.
  DOI: [10.1145/3457340.3458304](https://doi.org/10.1145/3457340.3458304)
- Guoxing Chen and Yinqian Zhang (2022), MAGE: Mutual Attestation for a Group of Enclaves without Trusted Third Parties. In *Proceedings of 31st USENIX Security Symposium (USENIX Security 22)*, USENIX Association, Boston, MA, 4095–4110.
  <https://www.usenix.org/conference/usenixsecurity22/presentation/chen-guoxing>
- S. C. Kleene (1938), On Notation for Ordinal Numbers, *The Journal of Symbolic Logic*, Vol. 3, No. 4, pp. 150–155.
  DOI: [10.2307/2267778](https://doi.org/10.2307/2267778)
- Kurt Gödel (1931), Über formal unentscheidbare Sätze der Principia Mathematica und verwandter Systeme I, *Monatsh. f. Mathematik und Physik*, Vol. 38, pp. 173–198.
  DOI: [10.1007/BF01700692](https://doi.org/10.1007/BF01700692)
- John von Neumann, edited and completed by Arthur W. Burks (1966). *Theory of Self-Reproducing Automata*, University of Illinois Press, Urbana and London.
- Haskell H. Curry, Robert Feys, William Craig (1958), *Combinatory Logic, Volume I*, North-Holland Publishing Company, Amsterdam.
