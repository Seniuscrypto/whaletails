use crate::*;
use anchor_spl::token_interface::{self, Mint, TokenAccount, TokenInterface, TransferChecked};

/// Whaletails, 2026-10-12: lock part of the supply in the escrow AND count it as
/// locked (tvl_ld), exactly as `send` does for an Adapter, but without a message.
///
/// Used once at launch: the other chain's OFT contract mints the same amount in
/// its constructor, so the coin opens on both chains at once with no bridge wait.
/// Without this, those tokens would sit in the escrow uncounted, and the first
/// transfer back to Solana would underflow `tvl_ld` in `lz_receive` and fail.
///
/// Admin only, Adapter only. Tokens arrive in the same instruction as the count
/// rises, so `tvl_ld <= escrow balance` always holds; it can only add backing.
#[derive(Accounts)]
pub struct LockSupply<'info> {
    pub admin: Signer<'info>,
    #[account(
        mut,
        seeds = [OFT_SEED, oft_store.token_escrow.as_ref()],
        bump = oft_store.bump,
        has_one = admin @OFTError::Unauthorized
    )]
    pub oft_store: Account<'info, OFTStore>,
    #[account(
        address = oft_store.token_mint,
        mint::token_program = token_program
    )]
    pub token_mint: InterfaceAccount<'info, Mint>,
    #[account(
        mut,
        address = oft_store.token_escrow,
        token::authority = oft_store,
        token::mint = token_mint,
        token::token_program = token_program
    )]
    pub token_escrow: InterfaceAccount<'info, TokenAccount>,
    #[account(
        mut,
        token::mint = token_mint,
        token::authority = admin,
        token::token_program = token_program
    )]
    pub token_source: InterfaceAccount<'info, TokenAccount>,
    pub token_program: Interface<'info, TokenInterface>,
}

impl LockSupply<'_> {
    pub fn apply(ctx: &mut Context<LockSupply>, params: &LockSupplyParams) -> Result<()> {
        require!(ctx.accounts.oft_store.oft_type == OFTType::Adapter, OFTError::NotAdapter);
        require!(
            params.amount_ld > 0 && params.amount_ld % ctx.accounts.oft_store.ld2sd_rate == 0,
            OFTError::InvalidAmount
        );
        ctx.accounts.oft_store.tvl_ld += params.amount_ld;
        token_interface::transfer_checked(
            CpiContext::new(
                ctx.accounts.token_program.to_account_info(),
                TransferChecked {
                    from: ctx.accounts.token_source.to_account_info(),
                    mint: ctx.accounts.token_mint.to_account_info(),
                    to: ctx.accounts.token_escrow.to_account_info(),
                    authority: ctx.accounts.admin.to_account_info(),
                },
            ),
            params.amount_ld,
            ctx.accounts.token_mint.decimals,
        )?;
        Ok(())
    }
}

#[derive(Clone, AnchorSerialize, AnchorDeserialize)]
pub struct LockSupplyParams {
    pub amount_ld: u64,
}
