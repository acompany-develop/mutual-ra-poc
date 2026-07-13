# Mutual Attestation PoC Implementation

This project provides a Proof of Concept implementation for a setting where several nodes attest to one another; each node verifies the others' **reference measurements** without any external source for those reference values. It employs the [PyReflect](https://github.com/acompany-develop/PyReflect) transpiler for mutual-reference programming.

## Overview

Consider two nodes, A and B, that attest to one another. Each node's attestation evidence carries a *measurement* of that node, and a verifier appraises it by comparing the measurement against a *reference value*. Conventionally, the reference values are supplied in one of two ways:

1. a trusted third party (a *Reference Value Provider*) distributes the reference measurements of A and B; or
2. each node hardcodes the reference measurement of the node(s) it is meant to verify.

Under (2), embedding each node's reference measurement into the other is self-contradicing. Writing B's measurement into A changes A's source, and hence A's measurement, which forces B to be updated, which in turn changes B's measurement, *ad infinitum*. This amounts to solving for a fixed point of the mutually-dependent hashes; assuming the hash function is computationally secure, doing so appears infeasible (though we are not aware of a proof).

This PoC avoids the infinite regress of (2) by embedding, in place of the reference measurement *value*, a function that *generates* it together with the data that function needs. Each node can then reconstruct the exact source of the other node from data carried within itself and hash it, so reference values are derived intrinsically rather than fetched from any external source (file, stdin, registry, ...). The construction is based on **Kleene's second recursion theorem**, and the mutual-reference transpilation is performed by [PyReflect](https://github.com/acompany-develop/PyReflect).

This repository focuses on the swTPM-backed mutual attestation: two nodes carry out a TPM-based attestation, verify each other's reference values, and then complete a handshake.

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

Expected:

```console
$ ./run.sh
== bring up one swtpm per node ==
n0 (re)started -> swtpm:path=/tmp/tpm/n0.sock
n1 (re)started -> swtpm:path=/tmp/tpm/n1.sock
== run node 1 (listener, vTPM n0) in background ==
[__NODE1] listening on 127.0.0.1:30303
== run node 2 (connector, vTPM n1) ==
[__NODE1] peer ref (self-computed): b2346a8f173808cb60b2c48cb7575729142dc66b99e40ba289fd8d1a631307a1
[__NODE1] peer AK hash (received) : 6375711a73ab07823e3d03df4bdeb1b93c159d754c659eea6fe4212f6cb84cd0
[__NODE2] peer ref (self-computed): 9b21fb62913f3a88fe6576ae2726107587ec153699e12ed3f3567a7a413497fa
[__NODE1] PCR23 recalculated      : 521bb26fde896df7a8a6f225078b17c86803de031c030705277b57f5a0baf1da
[__NODE1] PCR23 received          : 521bb26fde896df7a8a6f225078b17c86803de031c030705277b57f5a0baf1da
[__NODE2] peer AK hash (received) : 5f247386712881395139b8a24c82458a13f7af3ca469e6e784a860aadafe18da
[__NODE2] PCR23 recalculated      : 36ee7659bf57b35d305a8638ba7b1461e35f21af0a27a4202622ea8a1c280a3d
[__NODE2] PCR23 received          : 36ee7659bf57b35d305a8638ba7b1461e35f21af0a27a4202622ea8a1c280a3d
[__NODE1] peer __NODE2 : ATTESTATION VERIFIED
[__NODE1] session key established: 0ea1c4fa4da98c01ace5bcac50a285b1...
[__NODE2] peer __NODE1 : ATTESTATION VERIFIED
[__NODE2] session key established: 0ea1c4fa4da98c01ace5bcac50a285b1...
[__NODE2] peer says: 'hello from __NODE1' (MAC ok)
[__NODE1] peer says: 'hello from __NODE2' (MAC ok)
== done ==
$ sha256sum *.py
9b21fb62913f3a88fe6576ae2726107587ec153699e12ed3f3567a7a413497fa  node___NODE1.py
b2346a8f173808cb60b2c48cb7575729142dc66b99e40ba289fd8d1a631307a1  node___NODE2.py
```

### Protocol

1. Generate an ephemeral ECDH key and a 32-byte nonce; exchange them;
2. In the vTPM: create an ECDSA AK, `PCR23 = reset(0)`, then `extend(sha256(own file))` and `extend(sha256(ephemeral_pubkey))`;
3. `Quote(PCR23)` using the **peer's** nonce as qualifying data;
4. Exchange AK public key + PCR value + quote + signature;
5. Verify the peer's quote: signature under the peer AK, `extraData == my nonce` (freshness), and `pcrDigest == sha256(expected_pcr)`, where `expected_pcr` is replayed from the reproduced peer's source code and the received ephemeral public key;
6. on success, derive an ECDH + HKDF session key and exchange a MAC'd message.

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
