// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;


import './token.sol';
import "hardhat/console.sol";


contract TokenExchange is Ownable {
    string public exchange_name = 'BJCEX';

    address tokenAddr = 0x5FbDB2315678afecb367f032d93F642f64180aa3;                                  // TODO: paste token contract address here
    Token public token = Token(tokenAddr);                                

    // Liquidity pool for the exchange
    uint private token_reserves = 0;
    uint private eth_reserves = 0;

    mapping(address => uint) private lps; 
     
    // Needed for looping through the keys of the lps mapping
    address[] private lp_providers;                     

    // liquidity rewards
    uint private swap_fee_numerator = 5;                // TODO Part 5: Set liquidity providers' returns.
    uint private swap_fee_denominator = 100;
    
    uint private eth_fees_pool = 0;
    uint private tok_fees_pool = 0;

    // Constant: x * y = k
    uint private k;

    constructor() {}
    

    // Function createPool: Initializes a liquidity pool between your Token and ETH.
    // ETH will be sent to pool in this transaction as msg.value
    // amountTokens specifies the amount of tokens to transfer from the liquidity provider.
    // Sets up the initial exchange rate for the pool by setting amount of token and amount of ETH.
    function createPool(uint amountTokens)
        external
        payable
        onlyOwner
    {
        // This function is already implemented for you; no changes needed.

        // require pool does not yet exist:
        require (token_reserves == 0, "Token reserves was not 0");
        require (eth_reserves == 0, "ETH reserves was not 0.");

        // require nonzero values were sent
        require (msg.value > 0, "Need eth to create pool.");
        uint tokenSupply = token.balanceOf(msg.sender);
        require(amountTokens <= tokenSupply, "Not have enough tokens to create the pool");
        require (amountTokens > 0, "Need tokens to create pool.");

        token.transferFrom(msg.sender, address(this), amountTokens);
        token_reserves = token.balanceOf(address(this));
        eth_reserves = msg.value;
        k = token_reserves * eth_reserves;
    }

    // Function removeLP: removes a liquidity provider from the list.
    // This function also removes the gap left over from simply running "delete".
    function removeLP(uint index) private {
        require(index < lp_providers.length, "specified index is larger than the number of lps");
        lp_providers[index] = lp_providers[lp_providers.length - 1];
        lp_providers.pop();
    }

    // Function getSwapFee: Returns the current swap fee ratio to the client.
    function getSwapFee() public view returns (uint, uint) {
        return (swap_fee_numerator, swap_fee_denominator);
    }

    // ============================================================
    //                    FUNCTIONS TO IMPLEMENT
    // ============================================================
    
    // set precision for division as seen https://ethereum.stackexchange.com/questions/15090/cant-do-any-integer-division
    uint private PRECISION = 1000000; 

    // functions to return the exchange rate ("price") for ETH/Tokens or Tokens/ETH
    function getETHPrice() internal view returns (uint) {
        // NOTE: returns in precision units
        return token_reserves * PRECISION / eth_reserves;
    }

    function getTokenPrice() internal view returns (uint) {
        // NOTE: returns in precision units
        return eth_reserves * PRECISION / token_reserves;
    }

    // functions to return the exchange rate ("price") for ETH/Tokens or Tokens/ETH during swap 
    // NOTE: in this case need to take into account added values to stay on xy = k curve

    function getETHPriceSwap(uint eth_amount) internal view returns (uint) {
        // NOTE: returns in precision units
        return token_reserves * PRECISION / (eth_amount + eth_reserves);
    }

    function getTokenPriceSwap(uint tok_amount) internal view returns (uint) {
        // NOTE: returns in precision units
        return eth_reserves * PRECISION / (tok_amount + token_reserves);
    }

    // function to update the shares of each lp after removeLiquidity is called 
    function updateLPs(address sender, uint old_eth_reserves, uint amountETH, bool subtract) internal {
        // get the number of lp providers w/ share > 0 
        uint lps_len = lp_providers.length; 
        // loop over lp providers, importantly starting at the end of the array, as we may delete entries
        for (uint i = lps_len - 1; i >= 0; i--) {
            address lp_i = lp_providers[i];

            // update the shares of each provider, multiplying by old and dividing by new reserves 
            if (lp_i == sender) {
                // if the sender we also need to account for the added/removed liquidity
                if (subtract) {
                    lps[lp_i] = (lps[lp_i] * old_eth_reserves - amountETH * PRECISION) / eth_reserves;
                } else {
                    lps[lp_i] = (lps[lp_i] * old_eth_reserves + amountETH * PRECISION) / eth_reserves;
                }
            } else {
                lps[lp_i] = lps[lp_i] * old_eth_reserves / eth_reserves;
            }

            // if provider's share = 0, we remove them from the list 
            if (subtract && lps[lp_i] == 0) { 
                removeLP(i);
            }

            if (i == 0) break;  // NOTE: need to break as i is a uint; will overflow
        }    
    }

    /* ========================= Liquidity Provider Functions =========================  */ 

    // Function addLiquidity: Adds liquidity given a supply of ETH (sent to the contract as msg.value).
    // You can change the inputs, or the scope of your function, as needed.
    function addLiquidity(uint max_exchange_rate, uint min_exchange_rate) 
        external 
        payable
    {
        /******* TODO: Implement this function *******/

        // reinvest rewards into liquidity pool (to ensure all values are synched)
        eth_reserves += eth_fees_pool;
        eth_fees_pool = 0;  // reset 

        token_reserves += tok_fees_pool; 
        tok_fees_pool = 0; 

        // make sure sent ETH is positive 
        require(msg.value > 0, "Passed in ETH value must be greater than zero.");

        // check exchange rate is OK to guard against slippage
        uint exchange_rate = getETHPrice();
        require(exchange_rate <= max_exchange_rate && exchange_rate >= min_exchange_rate, "Invalid exchange rate."); 

        // get corresponding amount of tokens
        uint tokens = msg.value * exchange_rate / PRECISION;
        // before transferring need to ensure sufficient funds in sender's allowance 
        uint sender_balance = token.allowance(msg.sender, address(this));
        require(sender_balance >= tokens, "Insufficient token balance for sender.");

        // transfer equiv amount of tokens from senders address to contract 
        token.transferFrom(msg.sender, address(this), tokens);

        // update reserves, k to newest state 
        uint old_eth_reserves = eth_reserves; 
        token_reserves = token.balanceOf(address(this));
        eth_reserves = address(this).balance;
        k = token_reserves * eth_reserves; 

        // if the sender is a new provider, we add them to our list 
        if (lps[msg.sender] == 0) {
            lp_providers.push(msg.sender);
        }
        
        // update pool shares for every lp provider
        updateLPs(msg.sender, old_eth_reserves, msg.value, false);
    }


    // Function removeLiquidity: Removes liquidity given the desired amount of ETH to remove.
    // You can change the inputs, or the scope of your function, as needed.
    function removeLiquidity(uint amountETH, uint max_exchange_rate, uint min_exchange_rate)
        public 
        payable
    {
        /******* TODO: Implement this function *******/

        // reinvest rewards into liquidity pool (to ensure all values are synched)
        eth_reserves += eth_fees_pool;
        eth_fees_pool = 0;  // reset

        token_reserves += tok_fees_pool; 
        tok_fees_pool = 0; 

        // check that no ETH has been sent
        require(msg.value == 0, "Transaction should not contain any value.");

        // check amountETH to remove is positive 
        require(amountETH > 0, "Provided ETH amount must be greater than zero.");

        // cannot withdraw more than in reserves (won't drain reserves to 0)
        require(amountETH <= eth_reserves, "Insufficient ETH reserves for request.");
        
        // check exchange rate is OK to guard against slippage
        uint exchange_rate = getETHPrice();
        require(exchange_rate <= max_exchange_rate && exchange_rate >= min_exchange_rate, "Invalid exchange rate.");    

        // get corresponding amount of tokens to withdraw 
        uint tokens = amountETH * exchange_rate / PRECISION;
        // cannot withdraw more than in reserves (won't drain reserves to 0)
        require(tokens <= token_reserves, "Insufficient token reserves for request.");

        // ensure sender has the necessary funds
        uint pool_value = lps[msg.sender] * eth_reserves; 
        require(amountETH * PRECISION <= pool_value, "User has insufficient funds to remove this amount of ETH.");

        // send tokens to sender 
        token.transfer(msg.sender, tokens);
        // send ETH to sender: need to cast sender as payable re: https://ethereum.stackexchange.com/questions/113243/payablemsg-sender
        payable(msg.sender).transfer(amountETH);

        // update reserves, k to newest state 
        uint old_eth_reserves = eth_reserves; 
        token_reserves = token.balanceOf(address(this));
        eth_reserves = address(this).balance;
        k = token_reserves * eth_reserves;  

        // update pool shares
        updateLPs(msg.sender, old_eth_reserves, amountETH, true);
    }

    // Function removeAllLiquidity: Removes all liquidity that msg.sender is entitled to withdraw
    // You can change the inputs, or the scope of your function, as needed.
    function removeAllLiquidity(uint max_exchange_rate, uint min_exchange_rate)
        external
        payable
    {
        /******* TODO: Implement this function *******/
        // get the sender's total amount of ETH and call removeLiquidity with this value 
        uint amountETH = lps[msg.sender] * eth_reserves / PRECISION; 
        removeLiquidity(amountETH, max_exchange_rate, min_exchange_rate);
    }
    /***  Define additional functions for liquidity fees here as needed ***/
    // NOTE: eth_fees_pool and tok_fees_pool defined abvoe with other state vars

    /* ========================= Swap Functions =========================  */ 

    // Function swapTokensForETH: Swaps your token with ETH
    // You can change the inputs, or the scope of your function, as needed.
    function swapTokensForETH(uint amountTokens, uint max_exchange_rate)
        external 
        payable
    {
        /******* TODO: Implement this function *******/
        // check that amount of tokens is positive
        require(amountTokens > 0, "Provided token amount must be greater than zero.");

        // check that sender has sufficient tokens
        uint sender_balance = token.allowance(msg.sender, address(this));
        require(amountTokens <= sender_balance, "Insufficient token balance for sender.");  
        
        // transfer tokens
        token.transferFrom(msg.sender, address(this), amountTokens);

        // calculate fee, subtract from amount and add to fee pool
        uint amountTokensFee = amountTokens * swap_fee_numerator / swap_fee_denominator;
        amountTokens -= amountTokensFee;
        tok_fees_pool += amountTokensFee; 

        // check that exchange rate is OK to guard against slippage
        uint exchange_rate = getTokenPriceSwap(amountTokens); 
        require(exchange_rate <= max_exchange_rate, "Exchange rate exceeds provided maximum rate.");

        // calculate amount ETH 
        uint amountETH = amountTokens * exchange_rate / PRECISION; 
        
        // check that contract has sufficient ETH (>= 1 per spec)
        require(amountETH <= eth_reserves - 1, "Insufficient ETH reserves for request.");
    
        // send ETH 
        payable(msg.sender).transfer(amountETH);

        // update reserves 
        token_reserves += amountTokens;
        eth_reserves -= amountETH;

    }



    // Function swapETHForTokens: Swaps ETH for your tokens
    // ETH is sent to contract as msg.value
    // You can change the inputs, or the scope of your function, as needed.
    function swapETHForTokens(uint max_exchange_rate)
        external
        payable 
    {
        /******* TODO: Implement this function *******/
        // check that amount of ETH must be positive
        require(msg.value > 0, "Provided ETH amount must be greater than zero.");
         
        // calculate fee, subtract from amount and add to fee pool
        uint amountETHFee = msg.value * swap_fee_numerator / swap_fee_denominator; 
        uint amountETH = msg.value - amountETHFee; 
        eth_fees_pool += amountETHFee; 

        // check that exchange rate is OK to guard against slippage
        uint exchange_rate = getETHPriceSwap(amountETH); 
        require(exchange_rate <= max_exchange_rate, "Exchange rate exceeds provided maximum rate.");
   
        // convert ETH to tokens
        uint amountTokens = amountETH * exchange_rate / PRECISION; 
        
        // check that contract has sufficient tokens 
        require(amountTokens <= token_reserves - 1, "Insufficient token reserves for request.");

        // transfer tokens to the sender
        token.transfer(msg.sender, amountTokens);
        
        // update reserves 
        token_reserves -= amountTokens;
        eth_reserves += amountETH;
    }
}

