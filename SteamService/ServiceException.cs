namespace MotiscapeSteamService;

internal sealed class ServiceException : Exception
{
    public string Code { get; }

    public ServiceException(string code, string message) : base(message)
    {
        Code = code;
    }
}
