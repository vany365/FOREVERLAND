// Foreverland Gelato Web3 Function
// Handles: weekly harvest trigger + best-route compound selection
//
// Deploy this to Gelato's Web3 Functions at:
// https://app.gelato.network/web3-functions
//
// Required secrets (set in Gelato UI):
//   FOREVERLAND_LOCKER    - ForeverlandLocker contract address
//   FOREVERLAND_VAULT     - ForeverlandVault contract address
//   FOREVERLAND_RESOLVER  - ForeverlandResolver contract address
//   KURU_API_URL          - Kuru aggregator quote API endpoint
//   OPENSEA_API_KEY       - OpenSea API key for NFT listings
//   DUST_TOKEN            - DUST ERC-20 address
//   USDC_TOKEN            - USDC ERC-20 address
//   DUST_LOCK             - Neverland DustLock address

import {
  Web3Function,
  Web3FunctionContext,
} from "@gelatonetwork/web3-functions-sdk";
import { Contract, ethers } from "ethers";

// ─── ABIs ────────────────────────────────────────────────────────────────────

const RESOLVER_ABI = [
  "function checkerHarvest() view returns (bool canExec, bytes execPayload)",
  "function checkerCompound() view returns (bool canExec, bytes execPayload)",
];

const VAULT_ABI = [
  "function pendingUSDC() view returns (uint256)",
  "function minCompoundThreshold() view returns (uint256)",
  "function compoundViaDEX(address router, bytes swapData, uint256 minDustOut) external",
  "function compoundViaNFT(address seaport, tuple(tuple(address,address,tuple(uint8,address,uint256,uint256,uint256)[],tuple(uint8,address,uint256,uint256,uint256,address)[],uint8,uint256,uint256,bytes32,uint256,bytes32,uint256) parameters, bytes signature) order, uint256 expectedTokenId, uint256 minDustExpected) external",
];

const LOCKER_ABI = [
  "function harvest() external",
];

const DUST_LOCK_ABI = [
  "function locked(uint256 tokenId) view returns (tuple(int128 amount, uint256 end, bool isPermanent))",
  "function ownerOf(uint256 tokenId) view returns (address)",
];

// ─── Constants ───────────────────────────────────────────────────────────────

const MAX_SLIPPAGE_BPS    = 100;  // 1% max slippage on DEX
const NFT_DISCOUNT_BPS    = 50;   // Only buy NFT if at least 0.5% cheaper than DEX
const MIN_NFT_DUST_VALUE  = ethers.parseEther("1000"); // Ignore tiny NFTs

// ─── Main Web3 Function ──────────────────────────────────────────────────────

Web3Function.onRun(async (context: Web3FunctionContext) => {
  const { multiChainProvider, secrets } = context;
  const provider = multiChainProvider.default();

  // Load addresses from secrets
  const lockerAddr   = await secrets.get("FOREVERLAND_LOCKER");
  const vaultAddr    = await secrets.get("FOREVERLAND_VAULT");
  const resolverAddr = await secrets.get("FOREVERLAND_RESOLVER");
  const kuruApiUrl   = await secrets.get("KURU_API_URL");
  const openSeaKey   = await secrets.get("OPENSEA_API_KEY");
  const dustToken    = await secrets.get("DUST_TOKEN");
  const usdcToken    = await secrets.get("USDC_TOKEN");
  const dustLockAddr = await secrets.get("DUST_LOCK");

  if (!lockerAddr || !vaultAddr || !resolverAddr) {
    return { canExec: false, message: "Missing contract addresses in secrets" };
  }

  const resolver = new Contract(resolverAddr, RESOLVER_ABI, provider);
  const vault    = new Contract(vaultAddr, VAULT_ABI, provider);
  const dustLock = new Contract(dustLockAddr!, DUST_LOCK_ABI, provider);

  // ── Task 1: Check if harvest is needed ──────────────────────────────────
  const { canExec: harvestReady, execPayload: harvestPayload } =
    await resolver.checkerHarvest();

  if (harvestReady) {
    console.log("Harvest is ready — executing harvest()");
    return {
      canExec: true,
      callData: [
        {
          to: lockerAddr,
          data: harvestPayload,
        },
      ],
    };
  }

  // ── Task 2: Check if compound threshold is met ──────────────────────────
  const { canExec: compoundReady } = await resolver.checkerCompound();

  if (!compoundReady) {
    return { canExec: false, message: "Neither harvest nor compound needed" };
  }

  const pendingUSDC  = await vault.pendingUSDC();
  console.log(`Pending USDC to compound: ${ethers.formatUnits(pendingUSDC, 6)}`);

  // Take 10% fee into account for routing comparison
  const FEE_BPS     = 1000n;
  const DENOM       = 10000n;
  const usdcToSwap  = (pendingUSDC * (DENOM - FEE_BPS)) / DENOM;

  // ── Route A: Query Kuru aggregator ───────────────────────────────────────
  let kuruDustOut = 0n;
  let kuruSwapData = "0x";
  let kuruRouter   = ethers.ZeroAddress;

  try {
    const kuruRes = await fetch(
      `${kuruApiUrl}/quote?tokenIn=${usdcToken}&tokenOut=${dustToken}&amountIn=${usdcToSwap.toString()}&slippageBps=${MAX_SLIPPAGE_BPS}`
    );
    const kuruQuote = await kuruRes.json();
    kuruDustOut  = BigInt(kuruQuote.amountOut ?? "0");
    kuruSwapData = kuruQuote.calldata ?? "0x";
    kuruRouter   = kuruQuote.router ?? ethers.ZeroAddress;
    console.log(`Kuru quote: ${ethers.formatEther(kuruDustOut)} DUST`);
  } catch (e) {
    console.warn("Kuru quote failed:", e);
  }

  // ── Route B: Query Uniswap V3 on Monad ───────────────────────────────────
  // TODO: Replace with actual Uniswap V3 Quoter address on Monad once deployed
  // For now we use Kuru as primary
  const uniDustOut   = 0n; // placeholder
  const uniSwapData  = "0x";
  const uniRouter    = ethers.ZeroAddress;

  // ── Route C: Check OpenSea for discounted veDUST NFTs ────────────────────
  let bestNft: {
    tokenId: bigint;
    listingPriceUsdc: bigint;
    dustValue: bigint;
    dustPerUsdc: bigint;
    order: object;
  } | null = null;

  try {
    const osRes = await fetch(
      `https://api.opensea.io/v2/listings/collection/neverland-vedust/all?limit=20&order_by=price&order_direction=asc`,
      { headers: { "x-api-key": openSeaKey! } }
    );
    const osData = await osRes.json();

    for (const listing of osData.listings ?? []) {
      const tokenId     = BigInt(listing.protocol_data.parameters.offer[0].identifierOrCriteria);
      const priceWei    = BigInt(listing.price.current.value); // in USDC base units

      // Skip if too expensive for our budget
      if (priceWei > usdcToSwap) continue;

      // Read DUST locked in this NFT
      const locked = await dustLock.locked(tokenId);
      const dustValue: bigint = locked.amount < 0n ? 0n : BigInt(locked.amount);

      if (dustValue < MIN_NFT_DUST_VALUE) continue;

      // Calculate DUST per USDC for this NFT
      const dustPerUsdc = (dustValue * 10000n) / priceWei;

      if (!bestNft || dustPerUsdc > bestNft.dustPerUsdc) {
        bestNft = {
          tokenId,
          listingPriceUsdc: priceWei,
          dustValue,
          dustPerUsdc,
          order: listing.protocol_data,
        };
      }
    }
    if (bestNft) {
      console.log(
        `Best NFT: tokenId=${bestNft.tokenId}, dust=${ethers.formatEther(bestNft.dustValue)}, ` +
        `price=${ethers.formatUnits(bestNft.listingPriceUsdc, 6)} USDC`
      );
    }
  } catch (e) {
    console.warn("OpenSea query failed:", e);
  }

  // ── Select best route ─────────────────────────────────────────────────────
  const bestDexDustOut = kuruDustOut > uniDustOut ? kuruDustOut : uniDustOut;
  const bestDexRouter  = kuruDustOut > uniDustOut ? kuruRouter  : uniRouter;
  const bestDexData    = kuruDustOut > uniDustOut ? kuruSwapData : uniSwapData;

  let useNFT = false;
  if (bestNft) {
    // Compare NFT route: bestNft.dustValue for bestNft.listingPriceUsdc
    // vs DEX route: bestDexDustOut for usdcToSwap
    // Normalize to same USDC amount for fair comparison
    const nftDustNormalized = (bestNft.dustValue * usdcToSwap) / bestNft.listingPriceUsdc;
    const nftEdgeBps = ((nftDustNormalized - bestDexDustOut) * 10000n) / bestDexDustOut;

    console.log(`NFT edge over DEX: ${nftEdgeBps} bps`);
    if (nftEdgeBps >= BigInt(NFT_DISCOUNT_BPS)) {
      useNFT = true;
      console.log("Selecting NFT route");
    } else {
      console.log("Selecting DEX route (NFT not cheaper enough)");
    }
  }

  if (!useNFT) {
    // Execute DEX compound
    if (bestDexDustOut === 0n || bestDexRouter === ethers.ZeroAddress) {
      return { canExec: false, message: "No valid DEX route found" };
    }

    const minDustOut = (bestDexDustOut * BigInt(10000 - MAX_SLIPPAGE_BPS)) / 10000n;
    const vaultIface = new ethers.Interface(VAULT_ABI);
    const callData   = vaultIface.encodeFunctionData("compoundViaDEX", [
      bestDexRouter,
      bestDexData,
      minDustOut,
    ]);

    return {
      canExec: true,
      callData: [{ to: vaultAddr, data: callData }],
    };
  } else {
    // Execute NFT compound
    const minDustExpected = (bestNft!.dustValue * 9900n) / 10000n; // 1% buffer
    const vaultIface      = new ethers.Interface(VAULT_ABI);
    const callData        = vaultIface.encodeFunctionData("compoundViaNFT", [
      "0x0000000000000068F116a894984e2DB1123eB395", // Seaport 1.6 — update for Monad
      bestNft!.order,
      bestNft!.tokenId,
      minDustExpected,
    ]);

    return {
      canExec: true,
      callData: [{ to: vaultAddr, data: callData }],
    };
  }
});
