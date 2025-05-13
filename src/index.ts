import 'dotenv/config';
import { Client, Intents, MessageAttachment, MessageEmbed } from 'discord.js';
import { v4 as uuid } from 'uuid';
import tmp from 'tmp';
import Axios from 'axios';
import fs from 'fs';
import logger from './logger';
import obfuscate from './obfuscate';
import chalk from 'chalk'; // cần cài: npm i chalk

const token = process.env.DISCORD_TOKEN;
const MAX_SIZE = 100000;

logger.log('Bot is starting ...');

const client = new Client({
    intents: [
        Intents.FLAGS.GUILDS,
        Intents.FLAGS.GUILD_MESSAGES,
        Intents.FLAGS.DIRECT_MESSAGES,
    ],
    partials: ['CHANNEL'],
});

client.login(token);

client.once('ready', () => {
    logger.log(`Logged in as ${(client.user?.tag || 'Unknown')}`);
});

// Help command content
const showHelp = (message) => {
    const helpEmbed = new MessageEmbed()
        .setColor('#0099ff')
        .setTitle('Xeter Hub - Help Guide')
        .setDescription('This bot obfuscates Lua code to protect your scripts.')
        .addFields(
            { name: '📌 How to Use', value: 'There are 2 ways to submit code for obfuscation:\n1. Upload a .lua file as an attachment\n2. Send code in a code block ```lua ... ```' },
            { name: '🔰 Available Commands', value: 
                '**!weak** - Light obfuscation, more readable but less secure\n' +
                '**!medium** - Balanced obfuscation, good mix of security and performance\n' +
                '**!strong** - Heavy obfuscation, difficult to read but affects performance\n' +
                '**!help** - Display this help guide'
            },
            { name: '⚠️ Limitations', value: 'Currently the bot only processes files under 100KB in size' },
        )
        .setFooter({ text: 'Xeter Hub - https://discord.com/invite/hcJ8PHtkfy' });

    message.reply({ embeds: [helpEmbed] });
};

client.on('messageCreate', async (message) => {
    if (message.author.bot) return;

    const content = message.content.toLowerCase();
    
    // Handle help command
    if (content.includes('!help')) {
        showHelp(message);
        return;
    }
    
    const fileUrl = message.attachments.first()?.url;

    let preset: string | null = null;
    if (content.includes('!weak')) preset = 'Weak';
    else if (content.includes('!medium')) preset = 'Medium';
    else if (content.includes('!strong')) preset = 'Strong';
    if (!preset) return;

    const typingInterval = setInterval(() => {
        message.channel.sendTyping().catch(() => {});
    }, 8000);
    message.channel.sendTyping().catch(() => {});

    try {
        let code = '';
        let tmpFile;

        if (fileUrl) {
            const response = await Axios({
                method: 'GET',
                url: fileUrl,
                responseType: 'stream',
            });

            if (response.headers['content-length'] && Number.parseInt(response.headers['content-length'], 10) > MAX_SIZE) {
                clearInterval(typingInterval);
                await message.reply('Bot Is In Testing, Please Use Files Under 100Kb!');
                return;
            }

            tmpFile = tmp.fileSync({ postfix: '.lua' });
            const writeStream = fs.createWriteStream(tmpFile.name);
            response.data.pipe(writeStream);

            await new Promise<void>((resolve, reject) => {
                response.data.on('end', resolve);
                response.data.on('error', reject);
            });
        } else {
            const match = message.content.match(/```(?:lua)?\n?([\s\S]*?)```/);
            if (!match || !match[1]) {
                clearInterval(typingInterval);
                return;
            }
            code = match[1].trim();
            tmpFile = tmp.fileSync({ postfix: '.lua' });
            fs.writeFileSync(tmpFile.name, code, 'utf-8');
        }

        let outFile;
        try {
            outFile = await obfuscate(tmpFile.name, preset);
        } catch (e) {
            clearInterval(typingInterval);
            await message.reply(`Error:\n${e}`);
            tmpFile.removeCallback();
            return;
        }

        const obfuscatedContent = fs.readFileSync(outFile.name, 'utf-8');
        const newContent = `--// Obfuscated By Xeter Hub [ https://discord.com/invite/hcJ8PHtkfy ]\n\n${obfuscatedContent}`;

        const finalFile = tmp.fileSync({ postfix: '.lua' });
        fs.writeFileSync(finalFile.name, newContent);

        const randomId = Math.floor(Math.random() * 1e16);
        const randomName = `Xeter_${randomId}.txt`;
        
        const attachment = new MessageAttachment(finalFile.name, randomName);
        await message.reply({ files: [attachment] });

        finalFile.removeCallback();
        outFile.removeCallback();
        tmpFile.removeCallback();

        console.log(`${chalk.cyan(message.author.tag || 'Unknown User')} -> ${fileUrl || 'Code block'} @ ${preset}`);
    } catch (error) {
        await message.reply('Đã xảy ra lỗi. Vui lòng thử lại sau.');
    } finally {
        clearInterval(typingInterval);
    }
});