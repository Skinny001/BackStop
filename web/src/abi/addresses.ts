// Deployed Backstop contract addresses, per chain.
// Source of truth: backstopv2 repo root `broadcast/Deploy.s.sol/<chainId>/run-latest.json`
// and `README.md`. Update this file whenever a new deployment lands.

export const unichainSepolia = {
  chainId: 1301,
  poolManager: "0x9B851BA8a469314EAafDDa5A0DD46B309E34cbd0",
  backstopHook: "0x37Cbf59e9A03a303d8B9409c3151374b08f10ac8",
  backstopRegistry: "0x64725eE80dA8d86b790b52F3c016a3b10c485D54",
  insuranceVault: "0xbc371b61052B4811424643cA41E9A4aFC94dc58e",
  // Demo pool tokens (currency0 is also the bond asset) -- see README "Deployed instance".
  currency0: "0x309C14339f77671305C1A8d020E9E081c6336251",
  currency1: "0x63Dbb10EA994AAc43D1E94d5429B4f28DfFC8BDa",
  // The protected pool's other PoolKey fields, needed to reconstruct the PoolKey struct
  // on-chain (e.g. for PoolManager reads or building a swap call).
  fee: 3000,
  tickSpacing: 60,
} as const;

export type BackstopDeployment = typeof unichainSepolia;

export const deployments = {
  unichainSepolia,
} as const;
