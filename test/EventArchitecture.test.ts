import { expect } from "chai";
import { ethers } from "hardhat";

const VERSION = 1n;

describe("Event Architecture", function () {
  async function deployFixture() {
    const [actor, verifier] = await ethers.getSigners();
    const factory = await ethers.getContractFactory("EventArchitectureHarness");
    const harness = await factory.deploy();
    await harness.waitForDeployment();
    return { harness, actor, verifier };
  }

  it("emits a versioned ClaimCreatedV1 event with indexed identifiers", async function () {
    const { harness, actor } = await deployFixture();
    const metadataHash = ethers.keccak256(ethers.toUtf8Bytes("claim-metadata"));

    const tx = await harness.emitClaimCreatedV1(7, actor.address, metadataHash);
    const receipt = await tx.wait();
    const block = await ethers.provider.getBlock(receipt!.blockNumber);

    await expect(tx)
      .to.emit(harness, "ClaimCreatedV1")
      .withArgs(7, actor.address, metadataHash, BigInt(block!.timestamp), VERSION);

    const log = receipt!.logs.find((entry) => {
      try {
        return harness.interface.parseLog(entry)?.name === "ClaimCreatedV1";
      } catch {
        return false;
      }
    });

    expect(log).to.not.equal(undefined);
    expect(log!.topics).to.have.length(4);
  });

  it("emits deterministic verification and slashing payloads", async function () {
    const { harness, verifier } = await deployFixture();
    const reason = ethers.keccak256(ethers.toUtf8Bytes("DOUBLE_VOTE"));

    await expect(harness.emitVerificationSubmittedV1(9, verifier.address, true, 1000))
      .to.emit(harness, "VerificationSubmittedV1")
      .withArgs(9, verifier.address, true, 1000, anyUint64, VERSION);

    await expect(harness.emitSlashExecutedV1(9, verifier.address, reason, 250))
      .to.emit(harness, "SlashExecutedV1")
      .withArgs(9, verifier.address, reason, 250, anyUint64, VERSION);
  });
});

function anyUint64(value: unknown): boolean {
  return typeof value === "bigint" && value >= 0n && value <= (1n << 64n) - 1n;
}
