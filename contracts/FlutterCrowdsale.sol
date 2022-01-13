pragma solidity ^0.5.0;

import "./helpers/Context.sol";
import "./helpers/Ownable.sol";
import "./helpers/IERC20.sol";
import "./helpers/SafeMath.sol";
import "./helpers/SafeERC20.sol";
import "./helpers/ReentrancyGuard.sol";

/**
 * @title FlutterCrowdsale
 * @dev FlutterCrowdsale is a base contract for managing a token crowdsale,
 * allowing investors to purchase tokens with ether. This contract implements
 * such functionality in its most fundamental form and can be extended to provide additional
 * functionality and/or custom behavior.
 * The external interface represents the basic interface for purchasing tokens, and conforms
 * the base architecture for crowdsales. It is *not* intended to be modified / overridden.
 * The internal interface conforms the extensible and modifiable surface of crowdsales. Override
 * the methods to add functionality. Consider using 'super' where appropriate to concatenate
 * behavior.
 */
contract FlutterCrowdsale is Context, Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // The token being sold
    IERC20 private _token;

    // Address where funds are collected
    address payable private _wallet;

    // How many token units a buyer gets per wei.
    // The rate is the conversion between wei and the smallest and indivisible token unit.
    // So, if you are using a rate of 1 with a ERC20Detailed token with 3 decimals called TOK
    // 1 wei will give you 1 unit, or 0.001 TOK.
    uint256 private _rate;

    // Amount of wei raised
    uint256 private _weiRaised;

    // Individually capped
    mapping(address => uint256) private _contributions;
    uint256 private _maxCap;


    /**
    * My custom states
     */
    // Investors' token amount
    uint256 private _minBuy;
    mapping(address => uint256) private _tokenAccrued;
    mapping(address => uint256) private _claimPeriods;
    mapping(address => uint256) private _claimPerPeriod;
    mapping(address => uint256[3]) periods; // [beneficiary][unix time 1, unix time 2, unix time 3, unix time 4]
    uint256 public tokenAmountBought;
    uint256 public tokenAmountClaimed;
    bool private isSaleOn;
    mapping(address => bool) private hasInvested;


    /**
     * Event for token purchase logging
     * @param purchaser who paid for the tokens
     * @param beneficiary who got the tokens
     * @param value weis paid for purchase
     * @param amount amount of tokens purchased
     */
    event TokensPurchased(address indexed purchaser, address indexed beneficiary, uint256 value, uint256 amount);


    // Custom event
    /**
     * Event for token claim logging
     * @param claimer who paid for the tokens
     * @param amount amount of tokens purchased
     */
    event TokensClaimed(address indexed claimer, uint256 amount);


    /**
     * @param rate Number of token units a buyer gets per wei
     * @dev The rate is the conversion between wei and the smallest and indivisible
     * token unit. So, if you are using a rate of 1 with a ERC20Detailed token
     * with 3 decimals called TOK, 1 wei will give you 1 unit, or 0.001 TOK.
     * @param wallet Address where collected funds will be forwarded to
     * @param token Address of the token being sold
     */
    constructor (uint256 rate, address payable wallet, IERC20 token, uint256 minBuy, uint256 maxCap) public {
        require(rate > 0, "Crowdsale: rate is 0");
        require(wallet != address(0), "Crowdsale: wallet is the zero address");
        require(address(token) != address(0), "Crowdsale: token is the zero address");
        require(minBuy > 0, "Crowdsale: minBuy must be greater than zero");
        require(maxCap> 0, "Crowdsale: maxCap must be greater than zero");

        _rate = rate;
        _wallet = wallet;
        _token = token;
        isSaleOn = true;
        _minBuy = minBuy;
        _maxCap = maxCap;
    }

    /**
     * @dev fallback function ***DO NOT OVERRIDE***
     * Note that other contracts will transfer funds with a base gas stipend
     * of 2300, which is not enough to call buyTokens. Consider calling
     * buyTokens directly when purchasing tokens from a contract.
     */
    function () external payable {
        buyTokens(_msgSender());
    }

    /**
     * @return the token being sold.
     */
    function token() public view returns (IERC20) {
        return _token;
    }

    /**
     * @return the address where funds are collected.
     */
    function wallet() public view returns (address payable) {
        return _wallet;
    }

    /**
     * @return the number of token units a buyer gets per wei.
     */
    function rate() public view returns (uint256) {
        return _rate;
    }

    /**
     * @return the amount of wei raised.
     */
    function weiRaised() public view returns (uint256) {
        return _weiRaised;
    }

    /**
     * @dev low level token purchase ***DO NOT OVERRIDE***
     * This function has a non-reentrancy guard, so it shouldn't be called by
     * another `nonReentrant` function.
     * @param beneficiary Recipient of the token purchase
     */
    function buyTokens(address beneficiary) public nonReentrant payable {
        require(msg.value >= _minBuy, "buyTokens: value less than minimum amount");
        uint256 weiAmount = msg.value;
        _preValidatePurchase(beneficiary, weiAmount);

        // calculate token amount to be created
        uint256 tokens = _getTokenAmount(weiAmount);

        // update state
        _weiRaised = _weiRaised.add(weiAmount);

        _processPurchase(beneficiary, tokens);
        emit TokensPurchased(_msgSender(), beneficiary, weiAmount, tokens);

        _updatePurchasingState(beneficiary, weiAmount);

        _forwardFunds();
        _postValidatePurchase(beneficiary, weiAmount);
    }

    /**
     * @dev Validation of an incoming purchase. Use require statements to revert state when conditions are not met.
     * Use `super` in contracts that inherit from Crowdsale to extend their validations.
     * Example from CappedCrowdsale.sol's _preValidatePurchase method:
     *     super._preValidatePurchase(beneficiary, weiAmount);
     *     require(weiRaised().add(weiAmount) <= cap);
     * @param beneficiary Address performing the token purchase
     * @param weiAmount Value in wei involved in the purchase
     */
    function _preValidatePurchase(address beneficiary, uint256 weiAmount) internal view {
        require(isSaleOn, "Crowdsale: Sale is NOT on");
        require(beneficiary != address(0), "Crowdsale: beneficiary is the zero address");
        require(weiAmount != 0, "Crowdsale: weiAmount is 0");
        require(_contributions[beneficiary].add(weiAmount) <= _maxCap, "IndividuallyCappedCrowdsale: beneficiary cap exceeded");
        this; // silence state mutability warning without generating bytecode - see https://github.com/ethereum/solidity/issues/2691
    }

    /**
     * @dev Validation of an executed purchase. Observe state and use revert statements to undo rollback when valid
     * conditions are not met.
     * @param beneficiary Address performing the token purchase
     * @param weiAmount Value in wei involved in the purchase
     */
    function _postValidatePurchase(address beneficiary, uint256 weiAmount) internal view {
        // solhint-disable-previous-line no-empty-blocks
    }

    /**
     * @dev Source of tokens. Override this method to modify the way in which the crowdsale ultimately gets and sends
     * its tokens.
     * @param beneficiary Address performing the token purchase
     * @param tokenAmount Number of tokens to be emitted
     */
    function _deliverTokens(address beneficiary, uint256 tokenAmount) internal {
        _token.safeTransfer(beneficiary, tokenAmount);
    }

    /**
     * @dev Executed when a purchase has been validated and is ready to be executed. Doesn't necessarily emit/send
     * tokens.
     * @param beneficiary Address receiving the tokens
     * @param tokenAmount Number of tokens to be purchased
     */
    function _processPurchase(address beneficiary, uint256 tokenAmount) internal {
        tokenAmountBought = tokenAmountBought.add(tokenAmount);

        // Send 40% of the token bought
        uint256 tokenToSend = tokenAmount.div(5).mul(2);
        uint256 tokenAmtAccrued = tokenAmount.sub(tokenToSend);
        _deliverTokens(beneficiary, tokenToSend);

        if(hasInvested[beneficiary]){
            _tokenAccrued[beneficiary] = _tokenAccrued[beneficiary].add(tokenAmtAccrued);
            _claimPerPeriod[beneficiary] = _claimPerPeriod[beneficiary].add((tokenAmtAccrued.div(_claimPeriods[beneficiary])));
        }else{
            hasInvested[beneficiary] = true;
            _tokenAccrued[beneficiary] = _tokenAccrued[beneficiary].add(tokenAmtAccrued);
            _claimPeriods[beneficiary] = 3;
            _claimPerPeriod[beneficiary] = tokenAmtAccrued.div(3);
            periods[beneficiary][0] = now + 12 weeks;
            periods[beneficiary][1] = now + 8 weeks;
            periods[beneficiary][2] = now + 4 weeks;
        }


        
    }

    /**
     * @dev Override for extensions that require an internal state to check for validity (current user contributions,
     * etc.)
     * @param beneficiary Address receiving the tokens
     * @param weiAmount Value in wei involved in the purchase
     */
    function _updatePurchasingState(address beneficiary, uint256 weiAmount) internal {
        _contributions[beneficiary] = _contributions[beneficiary].add(weiAmount);
        // solhint-disable-previous-line no-empty-blocks
    }

    /**
     * @dev Override to extend the way in which ether is converted to tokens.
     * @param weiAmount Value in wei to be converted into tokens
     * @return Number of tokens that can be purchased with the specified _weiAmount
     */
    function _getTokenAmount(uint256 weiAmount) internal view returns (uint256) {
        return weiAmount.mul(_rate);
    }

    /**
     * @dev Determines how ETH is stored/forwarded on purchases.
     */
    function _forwardFunds() internal {
        _wallet.transfer(msg.value);
    }


    /**
     * @dev Sets the maximum for every individual's contribution.
     * @param cap Wei limit for individual contribution
     */
    function setCap(uint256 cap) external onlyOwner {
        _maxCap = cap;
    }


    /**
     * @dev Returns the maximum cap.
     * @return Current maximum cap
     */
    function getCap() public view returns (uint256) {
        return _maxCap;
    }



    /**
     * @dev Returns the amount contributed so far by a specific beneficiary.
     * @param beneficiary Address of contributor
     * @return Beneficiary contribution so far
     */
    function getContribution(address beneficiary) public view returns (uint256) {
        return _contributions[beneficiary];
    }


    // Custom functions

    /**
     * @dev Sets a specific beneficiary's maximum contribution.
     * @param amt Wei minimum limit for individual contribution
     */
    function setMinBuy(uint256 amt) external onlyOwner {
        _minBuy = amt;
    }

    /**
     * @dev Returns the minimum amount to buy.
     * @return Current minimum amount to buy
     */
    function getMinBuy() public view returns (uint256) {
        return _minBuy;
    }


    /**
     * @dev Contract owner to start sale.
     */
    function startSale() external onlyOwner{
        require(!isSaleOn, "startSale: Sale is still on");
        isSaleOn = true;
    }

    /**
     * @dev Contract owner to start sale.
     */
    function stopSale() external onlyOwner{
        require(isSaleOn, "stopSale: Sale is NOT on");
        isSaleOn = false;
    }

    /**
     * @dev Returns the amount contributed so far by a specific beneficiary.
     * @param beneficiary Address of contributor
     * @return Beneficiary contribution so far
     */
    function withdrawAllToken(address beneficiary) public onlyOwner {
        require(_token.balanceOf(address(this)) > 0, "withdrawAllToken: Contract has no token");
        isSaleOn = false;
        _token.safeTransfer(beneficiary, _token.balanceOf(address(this)));
    }
    
    function getClaimPeriods(address claimer) public view returns(uint256){
        return _claimPeriods[claimer];
    }

    function getClaimPerPeriod(address claimer) public view returns(uint256){
        return _claimPerPeriod[claimer];
    }

    function getTokenAccrued(address investor) public view returns(uint256){
        return _tokenAccrued[investor];
    }

    /**
     * @dev Allow investors to claim accrued token.
     */
    function claimTokens(address claimer) public {
        
        require(_claimPeriods[claimer] > 0, "claimTokens: No claiming available");
        require(now >= periods[claimer][_claimPeriods[claimer].sub(1)], "claimTokens: Not yet time to claim");
        _claimPeriods[claimer] = _claimPeriods[claimer].sub(1);

        if(_claimPeriods[claimer] == 0){
            hasInvested[claimer] = false;
        }
        _tokenAccrued[claimer] = _tokenAccrued[claimer].sub(_claimPerPeriod[claimer]);
        tokenAmountClaimed = tokenAmountClaimed.add(_claimPerPeriod[claimer]);
        _token.safeTransfer(claimer, _claimPerPeriod[claimer]);

        emit TokensClaimed(claimer, _claimPerPeriod[claimer]);

    }
}
