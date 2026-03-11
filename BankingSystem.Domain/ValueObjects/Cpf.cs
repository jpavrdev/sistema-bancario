using BankingSystem.Domain.Common;
namespace BankingSystem.Domain.ValueObjects;

public sealed class Cpf : IEquatable<Cpf>
{
    public string Value { get; }

    private Cpf(string value) => Value = value;

    public static Result<Cpf> Create(string raw)
    {
        var digits = raw?.Replace(".", "").Replace("-", "").Trim() ?? "";

        if (digits.Length != 11)
            return Result.Failure<Cpf>(new Error("CpfInvalido", ErrorType.Validation, "CPF deve conter 11 digitos."));

        if (!digits.All(char.IsDigit))
            return Result.Failure<Cpf>(new Error("CpfInvalido", ErrorType.Validation, "CPF deve conter apenas números."));

        if (digits.Distinct().Count() == 1)
            return Result.Failure<Cpf>(new Error("CpfInvalido", ErrorType.Validation, "CPF inválido."));

        if (!HasValidCheckDigits(digits))
            return Result.Failure<Cpf>(new Error("CpfInvalido", ErrorType.Validation, "CPF não possui digitos válidos."));

        return Result.Success(new Cpf(digits));
    }

    private static bool HasValidCheckDigits(string digits)
    {
        return IsValidDigit(digits, 9) && IsValidDigit(digits, 10);
    }

    private static bool IsValidDigit(string digits, int position)
    {
        var sum = 0;
        for (var i = 0; i < position; i++)
            sum += (digits[i] - '0') * (position + 1 - i);

        var remainder = sum % 11;
        var expected = remainder < 2 ? 0 : 11 - remainder;

        return (digits[position] - '0') == expected;
    }

    public override string ToString() => $"{Value[..3]}.{Value[3..6]}.{Value[6..9]}-{Value[9..]}";
    public override bool Equals(object? obj) => Equals(obj as Cpf);
    public override int GetHashCode() => Value.GetHashCode();

    public bool Equals(Cpf? other) => other is not null && Value == other.Value;

}
