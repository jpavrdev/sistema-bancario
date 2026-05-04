using BankingSystem.Domain.Entities;
using BankingSystem.Domain.Common;
using Microsoft.Extensions.Time.Testing;

namespace BankingSystem.Tests.Entities;

public class UsuarioTests
{
    [Fact]
    public void Criar_ComNomeVazio_DeveRetornarFalha()
    {
        var fakeTimeProvider = new FakeTimeProvider();

        var result = Usuario.Criar("52998224725", "", "Silva", new DateOnly(1990, 1, 1), fakeTimeProvider);
        Assert.False(result.IsSuccess);
        Assert.Equal(ErrorType.Validation, result.Error!.Type);
        Assert.Equal("Nome é obrigatório.", result.Error!.Description);
    }

    [Fact]
    public void Criar_ComSobrenomeVazio_DeveRetornarFalha()
    {
        var fakeTimeProvider = new FakeTimeProvider();

        var result = Usuario.Criar("52998224725", "Carlos", "", new DateOnly(1990, 1, 1), fakeTimeProvider);
        Assert.False(result.IsSuccess);
        Assert.Equal(ErrorType.Validation, result.Error!.Type);
        Assert.Equal("Sobrenome é obrigatório.", result.Error!.Description);
    }

    [Fact]
    public void Criar_ComDataNascimentoVazia_DeveRetornarFalha()
    {
        var fakeTimeProvider = new FakeTimeProvider();

        var result = Usuario.Criar("52998224725", "Carlos", "Silva", default, fakeTimeProvider);
        Assert.False(result.IsSuccess);
        Assert.Equal(ErrorType.Validation, result.Error!.Type);
        Assert.Equal("Data de Nascimento é obrigatória.", result.Error!.Description);
    }

    [Fact]
    public void Criar_ComDadosValidos_DeveRetornarUsuario()
    {
        var fakeTimeProvider = new FakeTimeProvider();
        
        var result = Usuario.Criar("52998224725", "Carlos", "Silva", new DateOnly(1990, 1, 1), fakeTimeProvider);
        Assert.True(result.IsSuccess);
        Assert.Equal("Carlos", result.Value!.Nome);
        Assert.Equal("Silva", result.Value!.Sobrenome);
        Assert.Equal(new DateOnly(1990, 1, 1), result.Value!.DataNascimento);
        Assert.Equal("52998224725", result.Value!.Cpf.Value);
    }
}
