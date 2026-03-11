using BankingSystem.Domain.Entities;

namespace BankingSystem.Tests.Entities;

public class UsuarioTests
{
    [Fact]
    public void Criar_ComNomeVazio_DeveLancarArgumentException()
    {
        Assert.Throws<ArgumentException>(() =>
            Usuario.Criar(
                "52998224725",
                "",
                "Silva",
                new DateOnly(1990, 1, 1)
            )
        );
    }

    [Fact]
    public void Criar_ComSobrenomeVazio_DeveLancarArgumentException()
    {
        Assert.Throws<ArgumentException>(() =>
            Usuario.Criar(
                "52998224725",
                "Carlos",
                "",
                new DateOnly(1990, 1, 1)
            )
        );
    }

    [Fact]
    public void Criar_ComDataNascimentoVazia_DeveLancarArgumentException()
    {
        Assert.Throws<ArgumentException>(() =>
            Usuario.Criar(
                "52998224725",
                "Carlos",
                "Silva",
                default
            )
        );
    }

    [Fact]
    public void Criar_ComDadosValidos_DeveRetornarUsuario()
    {
        var usuario = Usuario.Criar(
            "52998224725",
            "Carlos",
            "Silva",
            new DateOnly(1990, 1, 1)
        );
        Assert.NotNull(usuario);
        Assert.Equal("Carlos", usuario.Nome);
        Assert.Equal("Silva", usuario.Sobrenome);
        Assert.Equal(new DateOnly(1990, 1, 1), usuario.DataNascimento);
        Assert.Equal("52998224725", usuario.Cpf.Value);
    }
}
