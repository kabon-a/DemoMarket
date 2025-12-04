// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

//Interface to hold functions is another .sol file
interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address a) external view returns (uint256);
    function allowance(address o, address s) external view returns (uint256);
    function approve(address s, uint256 v) external returns (bool);
    function transfer(address to, uint256 v) external returns (bool);
    function transferFrom(address f, address t, uint256 v) external returns (bool);
}
//2nd Interface to hold functions in an external file containing data required for the code (an oracle)
interface IPriceOracle {
    //getPrice() is supposed to get the price of the underlying asset or digitized asset in real-time
    function getPrice() external view returns (uint256 unitPrice, uint256 updatedAt);
    //isPeak() checks if the price of the asset is peaking (accelerating upwards & mid to high arbitrage)
    function isPeak() external view returns (bool);
}

abstract contract Ownable {
    address public owner;

    event OwnershipTransferred(address indexed previous, address indexed current);

    constructor() {
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero addr");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }
}

abstract contract ReentrancyGuard {
    uint256 private _status = 1;
    modifier nonReentrant() {
        require(_status == 1, "reentrant");
        _status = 2;
        _;
        _status = 1;
    }
}

contract CommodityToken is IERC20, Ownable {
    string public name;
    string public symbol;
    uint8  public decimals = 18;

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(
        string memory _name,
        string memory _symbol,
        uint256 initialSupply
    ) {
        name = _name;
        symbol = _symbol;
        _mint(msg.sender, initialSupply);
    }

    //function to return total suppliable ETH
    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }

    //function to return balance of ETH
    //@param a is the address to check the balance of
    function balanceOf(address a) external view override returns (uint256) {
        return _balances[a];
    }

    //function to return allowance of ETH
    //@param o is the owner of the allowance
    //@param s is the spender of the allowance
    function allowance(address o, address s) external view override returns (uint256) {
        return _allowances[o][s];
    }

    // Approve a transaction request, returns a boolean to indicate
    function approve(address s, uint256 v) external override returns (bool) {
        _allowances[msg.sender][s] = v;
        emit Approval(msg.sender, s, v);
        return true;
    }

    // Transfer tokens from admin to user, returns a boolean to indicate success or failure
    function transfer(address to, uint256 v) external override returns (bool) {
        _transfer(msg.sender, to, v);
        return true;
    }

    // Transfer tokens from one user to another, returns a boolean to indicate success or failure
    function transferFrom(address f, address t, uint256 v) external override returns (bool) {
        uint256 currentAllowance = _allowances[f][msg.sender];
        require(currentAllowance >= v, "allowance too low");
        _allowances[f][msg.sender] = currentAllowance - v;
        _transfer(f, t, v);
        return true;
    }

    function _transfer(address from, address to, uint256 v) internal {
        require(to != address(0), "zero to");
        uint256 bal = _balances[from];
        require(bal >= v, "balance too low");
        _balances[from] = bal - v;
        _balances[to] += v;
        emit Transfer(from, to, v);
    }

    function _mint(address to, uint256 v) internal {
        require(to != address(0), "zero to");
        _totalSupply += v;
        _balances[to] += v;
        emit Transfer(address(0), to, v);
    }
}

//A simple oracle to hold market data
contract SimpleOracle is IPriceOracle, Ownable {
    uint256 public price;       // price per 1 token 
    uint256 public lastUpdated; // timestamp to indicate the last time the price was updated
    bool    public peak;        // this is to indicate whether the market price of the commodity is peaking

    event PriceUpdated(uint256 price, uint256 timestamp);
    event PeakStatusUpdated(bool peak);

    function setPrice(uint256 newPrice) external onlyOwner {
        price = newPrice;
        lastUpdated = block.timestamp;
        emit PriceUpdated(newPrice, lastUpdated); //The price change is logged on the ethereum virtual machine
    }

    function setPeak(bool _isPeak) external onlyOwner {
        peak = _isPeak;
        emit PeakStatusUpdated(_isPeak);
    }


    function getPrice() external view override returns (uint256 unitPrice, uint256 updatedAt) {
        return (price, lastUpdated); 
    }

    function isPeak() external view override returns (bool) {
        return peak;
    }
}

/* Simple contract allows users to:
     - Approve this contract to spend their CommodityToken
     - During peak, they call sellAtDiscount(amount, discountBps)
     - They receive ETH from this contract's balance
 */

contract SimpleSeller is Ownable, ReentrancyGuard {
    IERC20 public immutable commodityToken;
    IPriceOracle public oracle;

    uint256 public feeBps;
    uint256 public maxDiscountBps = 5000; // this variable is to set the maximum amount of discount on the commodity price a user can request.
    uint256 public maxOracleAge = 10 minutes; //prevents using outdated market price (greater than 10 minutes)

    bool public paused;

    event Sold(
        address indexed seller,
        uint256 amountTokens,
        uint256 discountBps,
        uint256 unitPrice,
        uint256 grossPayout,
        uint256 fee,
        uint256 netPayout
    );// This event to store on the EVM when a user sells the commodity to the admin at the discount

    event LiquidityFunded(address indexed from, uint256 amount);
    event Paused(bool status);
    event ParamsUpdated(uint256 feeBps, uint256 maxDiscountBps, uint256 maxOracleAge); //to log when any of the parameters change

    modifier notPaused() {
        require(!paused, "paused");
        _;
    }

    constructor(
        address _commodityToken,
        address _oracle,
        uint256 _feeBps
    ) {
        require(_commodityToken != address(0) && _oracle != address(0), "zero addr");
        require(_feeBps <= 2000, "fee too high"); // cap 20%

        commodityToken = IERC20(_commodityToken);
        oracle = IPriceOracle(_oracle);
        feeBps = _feeBps;
    }

    /* The following functions are for admin capabilities*/

    // This function funds this contract with ETH to pay sellers // 
    function fundLiquidity() external payable onlyOwner {
        require(msg.value > 0, "zero value");
        emit LiquidityFunded(msg.sender, msg.value);
    }

    function withdrawETH(uint256 amount) external onlyOwner {
        payable(owner).transfer(amount);
    }

    function setOracle(address _oracle) external onlyOwner {
        require(_oracle != address(0), "zero addr");
        oracle = IPriceOracle(_oracle);
    }

    function setParams(
        uint256 _feeBps,
        uint256 _maxDiscountBps,
        uint256 _maxOracleAge
    ) external onlyOwner {
        require(_feeBps <= 2000, "fee too high");
        require(_maxDiscountBps <= 9000, "discount too high");
        feeBps = _feeBps;
        maxDiscountBps = _maxDiscountBps;
        maxOracleAge = _maxOracleAge;
        emit ParamsUpdated(_feeBps, _maxDiscountBps, _maxOracleAge);
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit Paused(_paused);
    }

    /* User functions */

    // Sell commodity for ETH at a discounted price during "peak"
    // discountBps is the variable to hold how much sicount from the market price
    function sellAtDiscount(uint256 amount, uint256 discountBps)
        external
        nonReentrant
        notPaused
    {
        require(amount > 0, "zero amount");
        require(discountBps <= maxDiscountBps, "discount too high");

        // To Check the data to see if the price is peaking or not, or if the market price i non-zero
        require(oracle.isPeak(), "not peak");
        (uint256 unitPrice, uint256 updatedAt) = oracle.getPrice();
        require(unitPrice > 0, "zero price");
        require(block.timestamp - updatedAt <= maxOracleAge, "stale price");

        uint256 discountedPrice = (unitPrice * (10_000 - discountBps)) / 10_000;
        uint256 grossPayout = amount * discountedPrice / 1e18;

        // apply fee for the transaction and saved money from discount
        uint256 fee = grossPayout * feeBps / 10_000;
        uint256 netPayout = grossPayout - fee;
        
        //this, ofcourse, ensures that there is enough money in the admin account for the payout to the user 
        require(address(this).balance >= grossPayout, "not enough ETH in contract");

        // Pull tokens from seller
        bool ok = commodityToken.transferFrom(msg.sender, address(this), amount);
        require(ok, "token transfer failed");

        // Pay ETH: fee to owner, net to seller
        if (fee > 0) {
            payable(owner).transfer(fee);
        }
        payable(msg.sender).transfer(netPayout);

        emit Sold(msg.sender, amount, discountBps, unitPrice, grossPayout, fee, netPayout);
    }
}
