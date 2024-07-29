// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import "./interface/PriceOracleInterface.sol";
import "./interface/IWRETH.sol";

/// @author Kane Wallmann (Rocket Pool)
/// @author ERC20 modified from Solmate (https://github.com/transmissions11/solmate/blob/main/src/tokens/ERC20.sol)
/// @author Modified from Uniswap (https://github.com/Uniswap/uniswap-v2-core/blob/master/contracts/UniswapV2ERC20.sol)
contract WRETH is IWRETH {
    IERC20 immutable public rETH;
    PriceOracleInterface immutable public oracle;

    // ERC20 constants
    uint256 constant public decimals = 18;
    string constant public name = "Wrapped Rocket Pool ETH";
    string constant public symbol = "wrETH";

    // last recorded rETH:ETH exchange rate
    uint256 public oracleRate;

    // Balances denominated in rETH
    uint256 public tokenTotalSupply;
    mapping(address => uint256) public tokenBalanceOf;

    // Allowances denominated in wrETH
    mapping(address => mapping(address => uint256)) public allowance;

    // EIP-2612 permit
    uint256 internal immutable INITIAL_CHAIN_ID;
    bytes32 internal immutable INITIAL_DOMAIN_SEPARATOR;
    mapping(address => uint256) public nonces;

    //
    // Events
    //

    event Rebase(uint256 previousRate, uint256 newRate);

    //
    // Constructor
    //

    /// @param _rETH Address for rETH token
    /// @param _oracle Address for the rETH rate oracle
    constructor(IERC20 _rETH, PriceOracleInterface _oracle) {
        rETH = _rETH;
        oracle = _oracle;
        // Record the initial rate
        oracleRate = oracle.rate();
        require(oracleRate != 0);
        // Domain separator
        INITIAL_CHAIN_ID = block.chainid;
        INITIAL_DOMAIN_SEPARATOR = computeDomainSeparator();
    }

    //
    // Rebasing functions
    //

    /// @notice Returns the current rETH:wrETH rate
    function rate() public view virtual returns (uint256) {
        return oracleRate;
    }

    /// @notice Retrieves the current rETH rate from oracle and rebases balances and supply
    function rebase() external virtual {
        uint256 newRate = oracle.rate();
        // Nothing to do
        if (newRate == oracleRate) {
            return;
        }
        require(newRate != 0);
        // Emit event
        emit Rebase(oracleRate, newRate);
        // Update the rate
        oracleRate = newRate;
    }

    /// @notice Transfers rETH from the caller and mints wrETH
    /// @param _amountTokens Amount to mint denominated in rETH
    function mint(uint256 _amountTokens) public returns (uint256) {
        require (_amountTokens > 0);
        // Calculate the value denominated in ETH
        uint256 amountWreth = wrethForTokens(_amountTokens);
        // Transfer that number of token to this contract
        require(rETH.transferFrom(msg.sender, address(this), _amountTokens), "Transfer failed");
        // Mint wrETH
        tokenTotalSupply += _amountTokens;
        // Cannot overflow because the sum of all user balances can't exceed the max uint256 value
        unchecked {
            tokenBalanceOf[msg.sender] += _amountTokens;
        }
        // Emit event
        emit Transfer(address(0), msg.sender, amountWreth);
        // Return amount of wrETH minted
        return amountWreth;
    }

    /// @notice Burns wrETH for rETH
    /// @param _amountWreth Amount of tokens to burn denominated in wrETH
    function burn(uint256 _amountWreth) external returns (uint256) {
        require (_amountWreth > 0);
        // Calculate the value denominated in rETH
        uint256 amountTokens = tokensForWreth(_amountWreth);
        // Transfer that number of token to this contract
        require(rETH.transfer(msg.sender, amountTokens), "Transfer failed");
        // Burn wrETH
        tokenTotalSupply -= amountTokens;
        // Cannot overflow because the sum of all user balances can't exceed the max uint256 value
        unchecked {
            tokenBalanceOf[msg.sender] -= amountTokens;
        }
        // Emit event
        emit Transfer(msg.sender, address(0), _amountWreth);
        // Return amount of rETH returned
        return amountTokens;
    }

    /// @notice Burns wrETH for rETH
    /// @param _amountTokens Amount of tokens to burn denominated in rETH
    function burnTokens(uint256 _amountTokens) public returns (uint256) {
        uint256 amountWreth = wrethForTokens(_amountTokens);
        // Transfer that number of token to this contract
        require(rETH.transfer(msg.sender, _amountTokens), "Transfer failed");
        // Burn wrETH
        tokenTotalSupply -= _amountTokens;
        // Cannot overflow because the sum of all user balances can't exceed the max uint256 value
        unchecked {
            tokenBalanceOf[msg.sender] -= _amountTokens;
        }
        // Emit event
        emit Transfer(msg.sender, address(0), amountWreth);
        // Returns amount of wrETH burned
        return amountWreth;
    }

    /// @notice Burns the caller's full balance of wrETH and returns rETH
    function burnAll() external {
        burnTokens(tokenBalanceOf[msg.sender]);
    }

    //
    // ERC20 logic
    //

    /// @notice Allows an owner to permit another account to transfer tokens
    /// @param spender Account to approve spending
    /// @param amount Amount to approve denominated in wrETH
    /// @return Always true
    function approve(address spender, uint256 amount) public virtual returns (bool) {
        require(spender != address(0));
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /// @notice Transfers tokens to another account
    /// @param to Recipient of the funds
    /// @param amount Amount to transfer denominated in wrETH
    /// @return Always true
    function transfer(address to, uint256 amount) public virtual returns (bool) {
        require(to != address(0));
        uint256 amountTokens = tokensForWreth(amount);
        tokenBalanceOf[msg.sender] -= amountTokens;
        // Cannot overflow because the sum of all user balances can't exceed the max uint256 value
        unchecked {
            tokenBalanceOf[to] += amountTokens;
        }
        emit Transfer(msg.sender, to, wrethForTokens(amountTokens));
        return true;
    }

    /// @notice Transfers tokens from one account to another
    /// @param from Account to spend funds from
    /// @param to Recipient of the funds
    /// @param amount Amount to approve denominated in wrETH
    /// @return Always true
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public virtual returns (bool) {
        require(to != address(0));
        uint256 allowed = allowance[from][msg.sender]; // Saves gas for limited approvals.
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        uint256 amountTokens = tokensForWreth(amount);
        tokenBalanceOf[from] -= amountTokens;
        // Cannot overflow because the sum of all user balances can't exceed the max uint256 value
        unchecked {
            tokenBalanceOf[to] += amountTokens;
        }
        emit Transfer(from, to, wrethForTokens(amountTokens));
        return true;
    }

    //
    // EIP-2612 logic
    //

    /// @notice Sets approval for another account based on EIP-2612 permit signature
    /// @param owner Account which owns the funds
    /// @param spender Account to permit spend
    /// @param value Value to approve denominated in wrETH
    /// @param deadline When the permit expires
    /// @param v ECDSA parity
    /// @param r ECDSA co-ordinate (r)
    /// @param s ECDSA co-ordinate (s)
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public virtual {
        require(deadline >= block.timestamp, "PERMIT_DEADLINE_EXPIRED");
        uint256 nonce = nonces[owner];

        bytes32 hash = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        keccak256(
                            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
                        ),
                        owner,
                        spender,
                        value,
                        nonce,
                        deadline
                    )
                )
            )
        );

        // Unchecked because the only math done is incrementing
        // the owner's nonce which cannot realistically overflow.
        unchecked {
            nonces[owner] = nonce + 1;
        }

        // Recover signer
        address recoveredAddress = ECDSA.recover(hash, v, r, s);
        require(recoveredAddress != address(0) && recoveredAddress == owner, "INVALID_SIGNER");

        // Update allowance
        allowance[recoveredAddress][spender] = value;
        emit Approval(owner, spender, value);
    }

    /// @notice Returns the EIP-712 domain separator for this token
    /// @return Domain separator hash
    function DOMAIN_SEPARATOR() public view virtual returns (bytes32) {
        return block.chainid == INITIAL_CHAIN_ID ? INITIAL_DOMAIN_SEPARATOR : computeDomainSeparator();
    }

    //
    // ERC20 views
    //

    /// @notice Returns the balance of the given account
    /// @param owner Account owner
    /// @return Balance of account denominated in wrETH
    function balanceOf(address owner) public view returns (uint256) {
        return wrethForTokens(tokenBalanceOf[owner]);
    }

    /// @notice Returns the total supply of this token
    /// @return Total supply denominated in wrETH
    function totalSupply() external view returns (uint256) {
        return wrethForTokens(tokenTotalSupply);
    }

    //
    // Internals
    //

    /// @dev Calculates the amount of rETH the supplied value of ETH is worth
    function tokensForWreth(uint256 _eth) public view returns (uint256) {
        return _eth * 1 ether / rate();
    }

    /// @dev Calculates the amount of ETH the supplied value of rETH is worth
    function wrethForTokens(uint256 _tokens) public view returns (uint256) {
        return _tokens * rate() / 1 ether;
    }

    /// @dev Computes and returns the EIP-712 domain separator
    function computeDomainSeparator() internal view virtual returns (bytes32) {
        return
            keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }
}
